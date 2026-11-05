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
  it("returns the defaults for no options", function()
    local cfg = config.validate()
    expect.equality(cfg, {
      tools = {},
      prompts = {},
      context = {},
      watch = true,
      herdr = { enabled = true },
      rex = { enabled = true },
    })
  end)

  it("accepts a full valid configuration", function()
    local cfg, err = config.validate({
      watch = false,
      herdr = { enabled = false },
      rex = { enabled = true, bin = "/x/rex", server = "unix:///tmp/s.sock" },
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
  end)

  it("names the key path for a bad option", function()
    expect.equality(path_of({ watch = "yes" }), "watch")
    expect.equality(path_of({ herdr = { enabled = "yes" } }), "herdr.enabled")
    expect.equality(path_of({ rex = { bin = 3 } }), "rex.bin")
    expect.equality(path_of({ rex = { server = false } }), "rex.server")
    expect.equality(path_of({ tools = { claude = { cmd = {} } } }), "tools.claude.cmd")
    expect.equality(path_of({ tools = { claude = { cmd = { "a", 1 } } } }), "tools.claude.cmd[2]")
    expect.equality(path_of({ tools = { claude = { env = { A = 1 } } } }), "tools.claude.env.A")
    expect.equality(path_of({ tools = { claude = { url = 1 } } }), "tools.claude.url")
    expect.equality(path_of({ tools = { claude = { mux_focus = "x" } } }), "tools.claude.mux_focus")
    expect.equality(path_of({ tools = { claude = { location = "fancy" } } }), "tools.claude.location")
    expect.equality(path_of({ tools = { claude = { is_proc = 4 } } }), "tools.claude.is_proc")
    expect.equality(path_of({ tools = { claude = { is_proc = "\\(" } } }), "tools.claude.is_proc")
    expect.equality(path_of({ tools = { claude = true } }), "tools.claude")
    expect.equality(path_of({ prompts = { x = 1 } }), "prompts.x")
    expect.equality(path_of({ prompts = { x = { msg = 1 } } }), "prompts.x.msg")
    expect.equality(path_of({ prompts = { x = { text = "a" } } }), "prompts.x")
    expect.equality(path_of({ context = { x = "a" } }), "context.x")
    expect.equality(path_of({ context = { x = false } }), "context.x")
  end)

  it("lists the allowed keys, sorted, in an unknown-key error", function()
    local _, err = config.validate({ nope = 1 })
    expect.equality(err.msg:find("allowed: context, herdr, prompts, rex, tools, watch", 1, true) ~= nil, true)
    _, err = config.validate({ rex = { nope = 1 } })
    expect.equality(err.msg:find("allowed: bin, enabled, server", 1, true) ~= nil, true)
    _, err = config.validate({ tools = { claude = { nope = 1 } } })
    expect.equality(err.msg:find("allowed: cmd, env, is_proc, location, mux_focus, url", 1, true) ~= nil, true)
  end)

  it("rejects unknown keys at every level", function()
    expect.equality(path_of({ nope = 1 }), "nope")
    expect.equality(path_of({ herdr = { nope = 1 } }), "herdr.nope")
    expect.equality(path_of({ rex = { nope = 1 } }), "rex.nope")
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
    first.tools.claude.env.A = "changed"
    first.context.mine = nil
    local second = config.get()
    expect.equality(second.watch, true)
    expect.equality(second.herdr.enabled, true)
    expect.equality(second.tools.claude.env.A, "1")
    expect.equality(second.context.mine == fn, true)
    expect.equality(vim.tbl_count(second.tools), 1)
    config.setup({})
  end)

  it("raises from setup naming the key path, and keeps the previous configuration", function()
    config.setup({ watch = false })
    local ok, err = pcall(config.setup, { tools = { claude = { cmd = "claude" } } })
    expect.equality(ok, false)
    expect.equality(err:find("tools.claude.cmd", 1, true) ~= nil, true)
    expect.equality(config.get().watch, false)
    config.setup({})
    expect.equality(config.get().watch, true)
  end)
end)
