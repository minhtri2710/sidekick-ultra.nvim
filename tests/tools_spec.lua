local expect = MiniTest.expect
local tools = require("sidekick-ultra.tools")

describe("tools", function()
  before_each(function()
    tools.setup()
  end)
  after_each(function()
    tools.setup()
  end)

  ---@param name string
  ---@param cmd string
  local function matches(name, cmd)
    return tools.get(name).is_proc({ pid = 1, cmd = cmd })
  end

  describe("built-ins", function()
    it("has the twelve tools", function()
      local names = vim.tbl_keys(tools.all())
      table.sort(names)
      expect.equality(names, {
        "aider",
        "amazon_q",
        "claude",
        "codex",
        "copilot",
        "crush",
        "cursor",
        "gemini",
        "grok",
        "opencode",
        "pi",
        "qwen",
      })
      expect.equality(
        vim.tbl_map(function(t)
          return t.name
        end, tools.list()),
        names
      )
    end)

    it("carries cmd, url, env, location style and mux_focus", function()
      expect.equality(tools.get("copilot").cmd, { "copilot", "--banner" })
      expect.equality(tools.get("amazon_q").cmd, { "q" })
      expect.equality(tools.get("cursor").cmd, { "cursor-agent" })
      expect.equality(tools.get("claude").url, "https://github.com/anthropics/claude-code")
      expect.equality(tools.get("opencode").env, { OPENCODE_THEME = "system" })
      expect.equality(tools.get("claude").location, "claude")
      expect.equality(tools.get("gemini").location, "escaped")
      expect.equality(tools.get("qwen").location, "escaped")
      expect.equality(tools.get("codex").location, "plain")
      expect.equality(tools.get("qwen").mux_focus, true)
      expect.equality(tools.get("claude").mux_focus, false)
    end)
  end)

  describe("process match", function()
    it("matches a whole word of the process string", function()
      expect.equality(matches("claude", "claude"), true)
      expect.equality(matches("claude", "/usr/local/bin/claude --resume"), true)
      expect.equality(matches("claude", "claudex"), false)
      expect.equality(matches("claude", "node"), false)
      expect.equality(matches("pi", "pi"), true)
      expect.equality(matches("pi", "pip"), false)
      expect.equality(matches("cursor", "cursor-agent"), true)
      expect.equality(matches("gemini", "gemini-cli"), true)
    end)

    it("treats a name with a non-word edge as one whole word", function()
      tools.setup({ cpp = { cmd = { "/usr/bin/c++" } }, dot = { cmd = { ".tool" } }, plus = { cmd = { "+x" } } })
      expect.equality(matches("cpp", "c++"), true)
      expect.equality(matches("cpp", "/usr/bin/c++ --flag"), true)
      expect.equality(matches("cpp", "c++-cli"), true)
      expect.equality(matches("cpp", "c++x"), false)
      expect.equality(matches("cpp", "xc++"), false)
      expect.equality(matches("cpp", "c+"), false)
      expect.equality(matches("dot", ".tool"), true)
      expect.equality(matches("dot", "/opt/bin/.tool --a"), true)
      expect.equality(matches("dot", "x.tool"), false)
      expect.equality(matches("dot", ".toolx"), false)
      expect.equality(matches("plus", "+x"), true)
      expect.equality(matches("plus", "/opt/+x --a"), true)
      expect.equality(matches("plus", "a+x"), false)
      expect.equality(matches("plus", "+xy"), false)
    end)

    it("matches nothing for a command whose basename is empty", function()
      tools.setup({ root = { cmd = { "/" } } })
      expect.equality(matches("root", "claude"), false)
      expect.equality(matches("root", "/"), false)
    end)

    it("matches amazon_q on qchat, not q", function()
      expect.equality(matches("amazon_q", "qchat"), true)
      expect.equality(matches("amazon_q", "q"), false)
    end)

    it("excludes the copilot language server", function()
      expect.equality(matches("copilot", "copilot"), true)
      expect.equality(matches("copilot", "node copilot --stdio language-server"), false)
    end)
  end)

  describe("setup", function()
    it("merges a user entry field by field and merges env", function()
      tools.setup({ claude = { cmd = { "claude", "--x" }, env = { A = "1" } }, opencode = { env = { B = "2" } } })
      expect.equality(tools.get("claude").cmd, { "claude", "--x" })
      expect.equality(tools.get("claude").url, "https://github.com/anthropics/claude-code")
      expect.equality(tools.get("claude").location, "claude")
      expect.equality(tools.get("claude").env, { A = "1" })
      expect.equality(tools.get("opencode").env, { OPENCODE_THEME = "system", B = "2" })
      expect.equality(matches("claude", "claude"), true)
    end)

    it("keeps a built-in's own program as its match when cmd is overridden", function()
      tools.setup({ claude = { cmd = { "/opt/bin/wrapper", "--x" } }, mine = { cmd = { "/opt/bin/wrapper" } } })
      expect.equality(tools.get("claude").cmd, { "/opt/bin/wrapper", "--x" })
      expect.equality(matches("claude", "claude"), true)
      expect.equality(matches("claude", "wrapper"), false)
      expect.equality(matches("mine", "wrapper"), true)
    end)

    it("removes a tool with false", function()
      tools.setup({ aider = false })
      expect.equality(tools.get("aider"), nil)
    end)

    it("adds a tool whose default match is its command basename", function()
      tools.setup({ mine = { cmd = { "/opt/bin/my.tool", "--a" } } })
      local tool = tools.get("mine")
      expect.equality(tool.name, "mine")
      expect.equality(tool.location, "plain")
      expect.equality(tool.mux_focus, false)
      expect.equality(tool.env, {})
      expect.equality(matches("mine", "/opt/bin/my.tool"), true)
      expect.equality(matches("mine", "myXtool"), false)
    end)

    it("takes is_proc as a Vim regex or a function", function()
      tools.setup({
        claude = { is_proc = "foo\\d" },
        mine = {
          cmd = { "mine" },
          is_proc = function(proc)
            return proc.pid == 42
          end,
        },
      })
      expect.equality(matches("claude", "foo1"), true)
      expect.equality(matches("claude", "claude"), false)
      expect.equality(tools.get("mine").is_proc({ pid = 42, cmd = "x" }), true)
      expect.equality(tools.get("mine").is_proc({ pid = 1, cmd = "mine" }), false)
    end)

    it("setup() with nothing restores the built-ins", function()
      tools.setup({ aider = false, extra = { cmd = { "extra" } } })
      tools.setup()
      expect.equality(tools.get("aider").name, "aider")
      expect.equality(tools.get("extra"), nil)
    end)
  end)

  describe("check", function()
    it("accepts a built-in entry without cmd, false, and a complete new tool", function()
      expect.equality(tools.check("claude", { env = { A = "1" } }), nil)
      expect.equality(tools.check("claude", false), nil)
      expect.equality(tools.check("mine", { cmd = { "mine" }, is_proc = "\\<mine\\>", location = "claude" }), nil)
    end)

    it("names the path and what was expected", function()
      expect.equality(tools.check("mine", {}), {
        path = "tools.mine.cmd",
        expected = "non-empty list of strings (required for a new tool)",
      })
      expect.equality(tools.check("claude", { mux_focus = "yes" }), {
        path = "tools.claude.mux_focus",
        expected = "boolean",
        got = "yes",
      })
      expect.equality(tools.check("claude", { location = "md" }), {
        path = "tools.claude.location",
        expected = "one of: plain, claude, escaped",
        got = "md",
      })
      expect.equality(tools.check("claude", { is_proc = "\\(" }), {
        path = "tools.claude.is_proc",
        expected = "valid Vim regex",
        got = "\\(",
      })
    end)

    it("lists the allowed fields for an unknown key", function()
      expect.equality(tools.check("claude", { nope = "x" }), {
        path = "tools.claude.nope",
        allowed = { "cmd", "env", "is_proc", "location", "mux_focus", "url" },
      })
    end)
  end)

  describe("installed", function()
    it("checks that cmd[1] is executable", function()
      expect.equality(tools.installed({ cmd = { "sh" } }), true)
      expect.equality(tools.installed({ cmd = { "sku-no-such-binary" } }), false)
    end)
  end)
end)
