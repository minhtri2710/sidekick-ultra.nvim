local expect = MiniTest.expect
local procname = require("sidekick-ultra.procname")

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
        { "node /x/bin/gemini", "gemini" },
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
      "node and bun: -r, --require, --import, --loader, --experimental-loader, -C, --conditions skip their value",
      function()
        for _, flag in ipairs({
          "-r",
          "--require",
          "--import",
          "--loader",
          "--experimental-loader",
          "-C",
          "--conditions",
        }) do
          check({ { "node " .. flag .. " ./hook.js /x/bin/gemini", "gemini" } })
        end
        check({ { "node -r a -r b /x/bin/gemini", "gemini" }, { "node --require a", "" } })
      end
    )

    it("node and bun: -e, --eval, -p, --print run code and give no script", function()
      for _, flag in ipairs({ "-e", "--eval", "-p", "--print" }) do
        check({ { "node " .. flag .. " code", "" }, { "node --inspect " .. flag .. " code /x/bin/gemini", "" } })
      end
      -- A value flag swallows the word after it, so an eval flag in that place is only a value.
      check({ { "node -r -e /x/bin/gemini", "gemini" } })
    end)

    it("node and bun: any other dash word, with or without =value, is skipped alone", function()
      check({
        { "node --inspect=9229 /x/bin/gemini", "gemini" },
        { "node --max-old-space-size=4096 --no-warnings /x/bin/gemini", "gemini" },
        { "node --no-warnings /x/bin/gemini", "gemini" },
        { "bun --bun /x/bin/gemini", "gemini" },
        { "node -pe /x/bin/gemini", "gemini" },
        { "node --require=./hook.js /x/bin/gemini", "gemini" },
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

    it("python: -W and -X skip their value", function()
      check({
        { "python3 -W ignore /x/bin/aider", "aider" },
        { "python3 -X dev -W error /x/bin/aider", "aider" },
        { "python3 -X dev -m aider", "aider" },
        { "python3 -W", "" },
      })
    end)

    it("python: any other dash word is skipped alone, and the first other word is the script", function()
      check({
        { "python3 -u /x/bin/aider", "aider" },
        { "python3 -B -OO -I /x/bin/aider", "aider" },
        { "python3 -Wignore /x/bin/aider", "aider" },
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
    it("misreads a script path with spaces, which fails closed", function()
      check({ { "node /x/my tools/bin/gemini", "my" } })
    end)
  end)
end)
