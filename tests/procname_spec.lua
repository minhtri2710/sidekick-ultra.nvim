local exec = require("sidekick-ultra.exec")
local expect = MiniTest.expect
local proc = require("sidekick-ultra.proc")
local procname = require("sidekick-ultra.procname")
local tools = require("sidekick-ultra.tools")

describe("procname", function()
  describe("is_interpreter", function()
    it("takes node, nodejs, bun, python, python3, python3.<N> and Python", function()
      for _, name in ipairs({ "node", "nodejs", "bun", "python", "python3", "python3.12", "python3.9", "Python" }) do
        expect.equality({ name, procname.is_interpreter(name) }, { name, true })
      end
    end)

    it("takes nothing else, whatever contains an interpreter's name", function()
      for _, name in ipairs({
        "claude",
        "gemini",
        "nodemon",
        "node-gyp",
        "python2",
        "python3.x",
        "python3.12.1",
        "pythonw",
        "Python3",
        "NODE",
        "bunx",
        "sh",
        "",
      }) do
        expect.equality({ name, procname.is_interpreter(name) }, { name, false })
      end
    end)
  end)

  describe("program", function()
    local function check(cases)
      for _, case in ipairs(cases) do
        expect.equality({ case[1], procname.program(case[1]) }, { case[1], case[2] })
      end
    end

    it("is the basename of the first word for a program that is not an interpreter", function()
      check({
        { "claude", "claude" },
        { "/usr/local/bin/claude --flag value", "claude" },
        { "  /opt/bin/claude\n", "claude" },
        { "/usr/local/bin/claudex", "claudex" },
        { "/bin/sh -c claude", "sh" },
        { "nodemon /x/bin/gemini", "nodemon" },
      })
    end)

    it("is nil for an empty line", function()
      check({ { "", nil }, { "   \n", nil } })
    end)

    it("takes the interpreter by the basename of its path", function()
      check({
        { "/opt/homebrew/bin/node /x/bin/gemini", "gemini" },
        { "/usr/bin/bun /x/bin/gemini", "gemini" },
        { "nodejs /x/bin/gemini", "gemini" },
        { "/usr/bin/python3 /x/bin/aider", "aider" },
        { "/usr/bin/python /x/bin/aider", "aider" },
        { "python3.12 /x/bin/aider", "aider" },
        {
          "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Resources/Python /x/aider",
          "aider",
        },
      })
    end)

    it("node and bun: the first word that is not a flag is the script", function()
      check({
        { "node /x/bin/gemini", "gemini" },
        { "node /x/bin/gemini --api-key value", "gemini" },
        { "node /x/bin/gemini -e", "gemini" },
      })
    end)

    it("node and bun: -- makes the next word the script, even a dash word", function()
      check({
        { "node -- /x/bin/gemini", "gemini" },
        { "node --inspect -- /x/bin/gemini --api-key value", "gemini" },
        { "node -- --odd", "--odd" },
        { "node --", "" },
      })
    end)

    it(
      "node and bun: --require, --import, --loader, --experimental-loader, --conditions skip their value, each time",
      function()
        for _, flag in ipairs({ "--require", "--import", "--loader", "--experimental-loader", "--conditions" }) do
          check({ { "node " .. flag .. " ./hook.js /x/bin/gemini", "gemini" } })
        end
        check({ { "node --require a --require b /x/bin/gemini", "gemini" }, { "node --require a", "" } })
      end
    )

    it("node and bun: -e, --eval, -p, --print run code and give no script", function()
      for _, flag in ipairs({ "-e", "--eval", "-p", "--print" }) do
        check({ { "node " .. flag .. " code", "" }, { "node --inspect " .. flag .. " code /x/bin/gemini", "" } })
      end
      -- A value flag swallows the word after it, so an eval flag in that place is only a value.
      check({ { "node -r -e /x/bin/gemini", "gemini" } })
    end)

    it("node and bun: --eval=, --print= and --run= run code and give no script", function()
      check({
        { "node --eval=code /x/bin/gemini", "" },
        { "node --inspect --print=code /x/bin/gemini", "" },
        { "bun --eval=code /x/bin/gemini", "" },
        { "node --run dev /x/bin/gemini", "" },
        { "node --run=dev /x/bin/gemini", "" },
      })
    end)

    it("node and bun: a lone - reads the script from stdin and gives no script", function()
      check({ { "node - /x/bin/gemini", "" }, { "node --inspect - /x/bin/gemini", "" }, { "bun - /x/bin/gemini", "" } })
    end)

    it("node and bun: a short cluster with e or p runs code and gives no script", function()
      check({
        { "node -pe code /x/bin/gemini", "" },
        { "node -ep code /x/bin/gemini", "" },
        { "node --inspect -pi code /x/bin/gemini", "" },
        { "bun -pe code /x/bin/gemini", "" },
      })
    end)

    it("node and bun: a short cluster without e or p is skipped as one word", function()
      check({ { "node -ic /x/bin/gemini", "gemini" }, { "node -hv /x/bin/gemini", "gemini" }, { "node -ic", "" } })
    end)

    it(
      "node and bun: a flag=value word is skipped as one word, a known value flag does not take the next word",
      function()
        check({
          { "node --inspect=9229 /x/bin/gemini", "gemini" },
          { "node --max-old-space-size=4096 --no-warnings /x/bin/gemini", "gemini" },
          { "node --require=./hook.js /x/bin/gemini", "gemini" },
          { "node --title=x --env-file=.env /x/bin/gemini", "gemini" },
          { "node --require=./hook.js", "" },
        })
      end
    )

    -- Each flag is listed with a value in `node --help` (v26.13.0), for example `--title=...`, and was probed on node
    -- v26.13.0: `node <flag> zz-none-probe.js` consumed the word (reviews/d10-help/node-probe.txt).
    it("node and bun: the flags node was probed to take a value skip it", function()
      for _, flag in ipairs({
        "--title",
        "--env-file",
        "--env-file-if-exists",
        "--input-type",
        "--inspect-port",
        "--debug-port",
        "--disable-warning",
        "--test-isolation",
        "--report-dir",
        "--unhandled-rejections",
        "-C",
        "-r",
      }) do
        check({ { "node " .. flag .. " value /x/bin/gemini", "gemini" }, { "node " .. flag .. " value", "" } })
      end
      check({ { "node --title gemini /x/bin/other", "other" }, { "node --env-file .env /x/bin/gemini", "gemini" } })
    end)

    -- The help line `--experimental-config-file, --experimental-default-config-file, --config-file=...` is wrong for
    -- these three: on node v26.13.0 the next word is the script (the config path comes from `--config-file=path`).
    it(
      "node and bun: --config-file, --experimental-config-file and --experimental-default-config-file take no value",
      function()
        for _, flag in ipairs({ "--config-file", "--experimental-config-file", "--experimental-default-config-file" }) do
          check({
            { "node " .. flag .. " /x/bin/gemini --key /x/bin/qwen", "gemini" },
            { "node " .. flag .. "=node.config.json /x/bin/gemini", "gemini" },
            { "node " .. flag, "" },
          })
        end
      end
    )

    it("node and bun: any other dash word is skipped alone", function()
      check({
        { "node --no-warnings /x/bin/gemini", "gemini" },
        { "bun --bun /x/bin/gemini", "gemini" },
        { "node", "" },
        { "node --inspect", "" },
      })
    end)

    it("drops one trailing .js, .mjs, .cjs or .py from the script, nothing else", function()
      check({
        { "node /x/dist/index.js", "index" },
        { "node /x/dist/index.mjs", "index" },
        { "node /x/dist/index.cjs", "index" },
        { "node /x/dist/index.py", "index" },
        { "python3 /x/bin/aider.py", "aider" },
        { "node /x/bin/gemini.js.js", "gemini.js" },
        { "node /x/bin/gemini.js.py", "gemini.js" },
        { "node /x/bin/gemini.ts", "gemini.ts" },
        { "node /x/bin/gemini.json", "gemini.json" },
        { "node /x/bin/.js", ".js" },
        { "node ./gemini", "gemini" },
        { "node gemini", "gemini" },
      })
    end)

    it("python: -m gives the module name as the script name", function()
      check({
        { "python3 -m aider", "aider" },
        { "python3 -m aider --model x", "aider" },
        { "python3 -u -m aider", "aider" },
        { "python3 -m pkg.sub", "pkg.sub" },
        { "python3 -m", "" },
      })
    end)

    it("python: -c runs code and gives no script", function()
      check({
        { "python3 -c code", "" },
        { "python3 -u -c code /x/bin/aider", "" },
        { "python3 -B -c", "" },
      })
    end)

    it("python: a lone - reads the script from stdin and gives no script", function()
      check({ { "python3 - /x/bin/aider", "" }, { "python3 -u - /x/bin/aider", "" } })
    end)

    it("python: a short cluster with c runs code and gives no script", function()
      check({
        { "python3 -uc code /x/bin/aider", "" },
        { "python3 -Ic code /x/bin/aider", "" },
        { "python3 -cCODE /x/bin/aider", "" },
        { "python3 -u -Bc code /x/bin/aider", "" },
      })
    end)

    -- `python3 --help` (3.9.6) shows `-W arg` and `-X opt` but not how a cluster splits, so a cluster with c or m fails
    -- closed: -Wc is -W with the value c (observed), and still gives no script.
    it(
      "python: a cluster with c or m gives no script, even after a value letter, or with the module attached",
      function()
        check({
          { "python3 -Wc /x/bin/aider", "" },
          { "python3 -Xdev=c /x/bin/aider", "" },
          { "python3 -maider /x/bin/other", "" },
          { "python3 -um aider", "" },
        })
      end
    )

    -- python 3.9.6 (observed; `python3 --help` is silent on clusters) scans a cluster left to right: at the first W or X
    -- the rest of the word is its value, and the next word when W or X is the last letter.
    it("python: a cluster scanned left to right takes the next word after a trailing W or X", function()
      check({
        { "python3 -uW ignore /x/bin/aider", "aider" },
        { "python3 -uX gemini /x/bin/aider", "aider" },
        { "python3 -bX dev -m aider", "aider" },
        { "python3 -uXW /x/bin/aider", "aider" },
        { "python3 -uW", "" },
        { "python3 -uX", "" },
      })
    end)

    it("python: -- makes the next word the script, even a dash word", function()
      check({
        { "python3 -- /x/bin/aider --token value", "aider" },
        { "python3 -u -- /x/bin/aider", "aider" },
        { "python3 -- -c", "-c" },
        { "python3 --", "" },
      })
    end)

    it("python: a short cluster without c or m is skipped as one word", function()
      check({
        { "python3 -uB /x/bin/aider", "aider" },
        { "python3 -Wignore /x/bin/aider", "aider" },
        { "python3 -Xfoo /x/bin/aider", "aider" },
        { "python3 -OO -Ib /x/bin/aider", "aider" },
        { "python3 -uB", "" },
      })
    end)

    it("python: -W, -X and --check-hash-based-pycs skip their value", function()
      check({
        { "python3 -W ignore /x/bin/aider", "aider" },
        { "python3 -X dev -W error /x/bin/aider", "aider" },
        { "python3 -X dev -m aider", "aider" },
        { "python3 --check-hash-based-pycs always /x/bin/aider", "aider" },
        { "python3 --check-hash-based-pycs always -m aider", "aider" },
        { "python3 -W", "" },
        { "python3 --check-hash-based-pycs always", "" },
      })
    end)

    it("python: a --flag=value word is skipped as one word", function()
      check({
        { "python3 --check-hash-based-pycs=always /x/bin/aider", "aider" },
        { "python3 --check-hash-based-pycs=always", "" },
      })
    end)

    it("python: any other dash word is skipped alone, and the first other word is the script", function()
      check({
        { "python3 -u /x/bin/aider", "aider" },
        { "python3 -B -OO -I /x/bin/aider", "aider" },
        { "python3 /x/bin/aider -m other", "aider" },
        { "python3 /x/bin/aider -c other", "aider" },
        { "python3", "" },
        { "python3 -u", "" },
      })
    end)

    it("splits on any run of whitespace", function()
      check({ { "  node \t -r   a  /x/bin/gemini   --x  ", "gemini" } })
    end)

    -- ponytail ceiling in procname.lua: words split on whitespace, so a path with spaces is misread and fails closed.
    it("misreads a script path with spaces, which fails closed: no tool matches", function()
      local line = "node /x/my tools/bin/gemini"
      check({ { line, "my" } })
      local orig = exec.run
      MiniTest.finally(function()
        exec.run = orig
      end)
      exec.run = function()
        return { code = 0, stdout = line .. "\n", stderr = "" }
      end
      -- The built-in matcher finds the word "gemini" anywhere in a command, so only the program name keeps it out.
      tools.setup()
      expect.equality({ proc.tool_of({ gemini = tools.get("gemini") }, 7, { "node" }) }, {})
    end)
  end)
end)
