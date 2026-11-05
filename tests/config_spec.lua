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
