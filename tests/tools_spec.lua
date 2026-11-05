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
    return tools.matches(tools.get(name), { pid = 1, cmd = cmd })
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
      expect.equality(tools.matches(tool, { pid = 1, cmd = "/opt/bin/my.tool" }), true)
      expect.equality(tools.matches(tool, { pid = 1, cmd = "myXtool" }), false)
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
      expect.equality(tools.matches(tools.get("mine"), { pid = 42, cmd = "x" }), true)
      expect.equality(tools.matches(tools.get("mine"), { pid = 1, cmd = "mine" }), false)
    end)

    it("setup() with nothing restores the built-ins", function()
      tools.setup({ aider = false, extra = { cmd = { "extra" } } })
      tools.setup()
      expect.equality(tools.get("aider").name, "aider")
      expect.equality(tools.get("extra"), nil)
    end)
  end)

  describe("installed", function()
    it("checks that cmd[1] is executable", function()
      expect.equality(tools.installed({ cmd = { "sh" } }), true)
      expect.equality(tools.installed({ cmd = { "sku-no-such-binary" } }), false)
    end)
  end)

  describe("location", function()
    local function loc(fields)
      return vim.tbl_extend("force", { path = "a.lua" }, fields)
    end

    it("plain", function()
      expect.equality(tools.location(loc({ kind = "file" })), "@a.lua")
      expect.equality(tools.location(loc({ kind = "line", r1 = 3 }), "plain"), "@a.lua :L3")
      expect.equality(tools.location(loc({ kind = "line", r1 = 3, r2 = 3 })), "@a.lua :L3")
      expect.equality(tools.location(loc({ kind = "line", r1 = 3, r2 = 5 })), "@a.lua :L3-L5")
      expect.equality(tools.location(loc({ kind = "position", r1 = 3, c1 = 4 })), "@a.lua :L3:C4")
      expect.equality(tools.location(loc({ kind = "position", r1 = 3, c1 = 4, r2 = 3, c2 = 4 })), "@a.lua :L3:C4")
      expect.equality(tools.location(loc({ kind = "position", r1 = 3, c1 = 4, r2 = 3, c2 = 9 })), "@a.lua :L3:C4-C9")
      expect.equality(tools.location(loc({ kind = "position", r1 = 3, c1 = 4, r2 = 5, c2 = 2 })), "@a.lua :L3:C4-L5:C2")
    end)

    it("claude", function()
      expect.equality(tools.location(loc({ kind = "file" }), "claude"), "@a.lua")
      expect.equality(tools.location(loc({ kind = "line", r1 = 10, r2 = 20 }), "claude"), "@a.lua#L10-20")
      expect.equality(tools.location(loc({ kind = "line", r1 = 10 }), "claude"), "@a.lua#L10")
      expect.equality(tools.location(loc({ kind = "position", r1 = 10, c1 = 5 }), "claude"), "@a.lua#L10 :C5")
      expect.equality(
        tools.location(loc({ kind = "position", r1 = 10, c1 = 5, r2 = 10, c2 = 8 }), "claude"),
        "@a.lua#L10 :C5-C8"
      )
      expect.equality(
        tools.location(loc({ kind = "position", r1 = 1, c1 = 2, r2 = 3, c2 = 4 }), "claude"),
        "@a.lua#L1-3"
      )
    end)

    it("claude quotes a path with unusual characters", function()
      expect.equality(tools.location(loc({ path = "my file.lua", kind = "file" }), "claude"), '@"my file.lua"')
      expect.equality(
        tools.location(loc({ path = "a(1).lua", kind = "line", r1 = 2, r2 = 4 }), "claude"),
        '@"a(1).lua"#L2-4'
      )
      expect.equality(
        tools.location(loc({ path = "dir/sub-1/a_b.lua", kind = "file" }), "claude"),
        "@dir/sub-1/a_b.lua"
      )
    end)

    it("escaped backslash-escapes every unusual path character", function()
      expect.equality(
        tools.location(loc({ path = "my file(1).lua", kind = "file" }), "escaped"),
        "@my\\ file\\(1\\).lua"
      )
      expect.equality(tools.location(loc({ path = "[No Name]", kind = "file" }), "escaped"), "@\\[No\\ Name\\]")
      expect.equality(
        tools.location(loc({ path = "a b.lua", kind = "line", r1 = 3, r2 = 5 }), "escaped"),
        "@a\\ b.lua :L3-L5"
      )
      expect.equality(tools.location(loc({ kind = "position", r1 = 3, c1 = 4 }), "escaped"), "@a.lua :L3:C4")
    end)

    it("plain leaves the path alone", function()
      expect.equality(tools.location(loc({ path = "my file.lua", kind = "file" }), "plain"), "@my file.lua")
    end)
  end)
end)
