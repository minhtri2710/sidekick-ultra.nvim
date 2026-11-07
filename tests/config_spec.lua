local backends = require("sidekick-ultra.backends")
local config = require("sidekick-ultra.config")

local expect = MiniTest.expect

---@param opts table
---@return string path
local function path_of(opts)
  local cfg, err = config.validate(opts)
  expect.equality(cfg, nil)
  return err.path
end

describe("config", function()
  after_each(function()
    config.setup({})
  end)

  it("returns the defaults for no options", function()
    local expected = { tools = {}, prompts = {}, context = {}, watch = true, keys = { prefix = "<leader>a" } }
    for _, name in ipairs(backends.names()) do
      expected[name] = { enabled = true }
    end
    expect.equality(config.validate(), expected)
  end)

  it("accepts keys as a prefix or false, and keeps the default prefix for an empty table", function()
    expect.equality(config.validate({ keys = { prefix = "<leader>S" } }).keys, { prefix = "<leader>S" })
    expect.equality(config.validate({ keys = false }).keys, false)
    expect.equality(config.validate({ keys = {} }).keys, { prefix = "<leader>a" })
  end)

  it("rejects a bad keys option, naming keys", function()
    expect.equality(path_of({ keys = "<leader>a" }), "keys")
    expect.equality(path_of({ keys = true }), "keys")
    expect.equality(path_of({ keys = { prefix = "" } }), "keys.prefix")
    expect.equality(path_of({ keys = { prefix = 1 } }), "keys.prefix")
    expect.equality(path_of({ keys = { prefix = false } }), "keys.prefix")
    expect.equality(path_of({ keys = { nope = 1 } }), "keys.nope")
    local _, err = config.validate({ keys = true })
    expect.equality(err.msg, "keys: expected table or false, got boolean")
    _, err = config.validate({ keys = { nope = 1 } })
    expect.equality(err.msg:find("allowed: prefix", 1, true) ~= nil, true)
  end)

  it("accepts a full valid configuration", function()
    local cfg, err = config.validate({
      watch = false,
      herdr = { enabled = false },
      rex = { enabled = true, bin = "/x/rex", server = "unix:///tmp/s.sock" },
      tmux = { enabled = true, socket = "/tmp/t.sock" },
      zellij = { enabled = false },
      tools = {
        claude = { env = { A = "b" }, mux_focus = true, location = "escaped", url = "https://x" },
        aider = false,
        mine = { cmd = { "mine", "--flag" }, is_proc = "\\<mine\\>" },
        other = {
          cmd = { "o" },
          is_proc = function()
            return true
          end,
        },
      },
      prompts = {
        a = "x",
        b = { msg = "y" },
        c = function()
          return "z"
        end,
        fix = false,
      },
      context = {
        mine = function()
          return "x"
        end,
      },
    })
    expect.equality(err, nil)
    expect.equality(cfg.watch, false)
    expect.equality(cfg.rex.server, "unix:///tmp/s.sock")
    expect.equality(cfg.herdr.enabled, false)
    expect.equality(cfg.tmux, { enabled = true, socket = "/tmp/t.sock" })
    expect.equality(cfg.zellij, { enabled = false })
  end)

  it("names the key path for a bad option", function()
    expect.equality(path_of({ watch = "yes" }), "watch")
    expect.equality(path_of({ herdr = { enabled = "yes" } }), "herdr.enabled")
    expect.equality(path_of({ rex = { bin = 3 } }), "rex.bin")
    expect.equality(path_of({ rex = { server = false } }), "rex.server")
    expect.equality(path_of({ tmux = { enabled = "yes" } }), "tmux.enabled")
    expect.equality(path_of({ tmux = { socket = 3 } }), "tmux.socket")
    expect.equality(path_of({ tmux = { socket = false } }), "tmux.socket")
    expect.equality(path_of({ zellij = { enabled = 1 } }), "zellij.enabled")
    expect.equality(path_of({ tmux = true }), "tmux")
    expect.equality(path_of({ zellij = "on" }), "zellij")
    expect.equality(path_of({ tools = { claude = { cmd = {} } } }), "tools.claude.cmd")
    expect.equality(path_of({ tools = { claude = { cmd = { "a", 1 } } } }), "tools.claude.cmd[2]")
    expect.equality(path_of({ tools = { claude = { env = { A = 1 } } } }), "tools.claude.env.A")
    expect.equality(path_of({ tools = { claude = { url = 1 } } }), "tools.claude.url")
    expect.equality(path_of({ tools = { claude = { is_proc = 4 } } }), "tools.claude.is_proc")
    expect.equality(path_of({ tools = { claude = true } }), "tools.claude")
    expect.equality(path_of({ prompts = { x = 1 } }), "prompts.x")
    expect.equality(path_of({ prompts = { x = { msg = 1 } } }), "prompts.x.msg")
    expect.equality(path_of({ prompts = { x = { text = "a" } } }), "prompts.x")
    expect.equality(path_of({ context = { x = "a" } }), "context.x")
    expect.equality(path_of({ context = { x = false } }), "context.x")
  end)

  it("rejects an empty string for every backend string option", function()
    expect.equality(path_of({ rex = { server = "" } }), "rex.server")
    expect.equality(path_of({ rex = { bin = "" } }), "rex.bin")
    expect.equality(path_of({ tmux = { socket = "" } }), "tmux.socket")
    local _, err = config.validate({ rex = { server = "" } })
    expect.equality(err.msg, "rex.server: expected non-empty string, got string")
  end)

  it("says a tool's empty first cmd word is not a non-empty string", function()
    local _, err = config.validate({ tools = { x = { cmd = { "" } } } })
    expect.equality(err.msg, "tools.x.cmd[1]: expected non-empty string, got string")
  end)

  it("rejects a context source whose name no placeholder can reach", function()
    local fn = function() end
    expect.equality(path_of({ context = { ["my-src"] = fn } }), "context.my-src")
    expect.equality(path_of({ context = { ["a b"] = fn } }), "context.a b")
    expect.equality(path_of({ context = { [""] = fn } }), "context.")
    expect.equality(path_of({ context = { this = fn } }), "context.this")
    local _, err = config.validate({ context = { this = fn } })
    expect.equality(
      err.msg,
      "context.this: expected a placeholder name (letters, digits and underscores, and not `this`), got string"
    )
    expect.equality(config.validate({ context = { my_src2 = fn } }).context.my_src2, fn)
  end)

  it("reports the problem of tools before prompts, and prompts before context", function()
    local bad = { tools = { claude = true }, prompts = { x = 1 }, context = { x = "a" } }
    expect.equality(path_of(bad), "tools.claude")
    bad.tools = nil
    expect.equality(path_of(bad), "prompts.x")
    bad.prompts = nil
    expect.equality(path_of(bad), "context.x")
  end)

  it("rejects a key that is not a string, with its text", function()
    local _, err = config.validate({ "x" })
    expect.equality(err.msg, "1: expected string key, got number")
    _, err = config.validate({ tools = { claude = { "x" } } })
    expect.equality(err.msg, "tools.claude.1: expected string key, got number")
  end)

  it("reports the first bad key in key order", function()
    expect.equality(path_of({ zeta = 1, alpha = 2 }), "alpha")
    expect.equality(path_of({ tools = { claude = { zeta = 1, alpha = 2 } } }), "tools.claude.alpha")
    expect.equality(path_of({ tools = { claude = { [1] = "x", nope = 1 } } }), "tools.claude.1")
  end)

  it("lists the allowed keys, sorted, in an unknown-key error", function()
    local _, err = config.validate({ nope = 1 })
    local allowed = vim.list_extend({ "context", "keys", "prompts", "tools", "watch" }, backends.names())
    table.sort(allowed)
    expect.equality(err.msg:find("allowed: " .. table.concat(allowed, ", "), 1, true) ~= nil, true)
    _, err = config.validate({ rex = { nope = 1 } })
    expect.equality(err.msg:find("allowed: bin, enabled, server", 1, true) ~= nil, true)
    _, err = config.validate({ tmux = { nope = 1 } })
    expect.equality(err.msg:find("allowed: enabled, socket", 1, true) ~= nil, true)
    _, err = config.validate({ zellij = { socket = "/x" } })
    expect.equality(err.msg:find("allowed: enabled", 1, true) ~= nil, true)
    _, err = config.validate({ tools = { claude = { nope = 1 } } })
    expect.equality(err.msg:find("allowed: cmd, env, is_proc, location, mux_focus, url", 1, true) ~= nil, true)
  end)

  it("rejects unknown keys at every level", function()
    expect.equality(path_of({ nope = 1 }), "nope")
    expect.equality(path_of({ herdr = { nope = 1 } }), "herdr.nope")
    expect.equality(path_of({ rex = { nope = 1 } }), "rex.nope")
    expect.equality(path_of({ tmux = { nope = 1 } }), "tmux.nope")
    expect.equality(path_of({ zellij = { socket = "/x" } }), "zellij.socket")
    expect.equality(path_of({ tools = { claude = { nope = 1 } } }), "tools.claude.nope")
  end)

  it("requires cmd for a new tool but not for a built-in one", function()
    expect.equality(path_of({ tools = { brandnew = { url = "x" } } }), "tools.brandnew.cmd")
    local cfg = config.validate({ tools = { claude = { url = "x" } } })
    expect.equality(cfg.tools.claude.url, "x")
  end)

  it("rejects options that are not a table", function()
    expect.equality(path_of(1), "opts")
  end)

  it("returns a copy: mutating the result of get() changes nothing", function()
    local fn = function() end
    config.setup({ watch = true, context = { mine = fn }, tools = { claude = { env = { A = "1" } } } })
    local first = config.get()
    first.watch = false
    first.herdr.enabled = false
    first.tmux.enabled = false
    first.tools.claude.env.A = "changed"
    first.context.mine = nil
    local second = config.get()
    expect.equality(second.watch, true)
    expect.equality(second.herdr.enabled, true)
    expect.equality(second.tmux.enabled, true)
    expect.equality(second.tools.claude.env.A, "1")
    expect.equality(second.context.mine == fn, true)
    expect.equality(vim.tbl_count(second.tools), 1)
  end)

  it("raises from setup naming the key path, and keeps the previous configuration", function()
    config.setup({ watch = false })
    local ok, err = pcall(config.setup, { tools = { claude = { cmd = "claude" } } })
    expect.equality(ok, false)
    expect.equality(err:find("tools.claude.cmd", 1, true) ~= nil, true)
    expect.equality(config.get().watch, false)
  end)

  it("resets to the defaults when setup is called with an empty table", function()
    config.setup({ watch = false, herdr = { enabled = false } })
    config.setup({})
    expect.equality({ config.get().watch, config.get().herdr.enabled }, { true, true })
  end)
end)
