local fake = require("tests.helpers.fake")
local notify = require("tests.helpers.notify")
local registry = require("sidekick-ultra.registry")
local sidekick = require("sidekick-ultra")

local expect = MiniTest.expect

local NAMES = { "herdr", "rex", "tmux", "zellij" }

describe("setup", function()
  local saved
  before_each(function()
    saved = { loaded = {}, preload = {} }
    for _, name in ipairs(NAMES) do
      local mod = "sidekick-ultra.backends." .. name
      saved.loaded[name], saved.preload[name] = package.loaded[mod], package.preload[mod]
      -- Every real module is replaced by a fake that reports its binary missing, so nothing depends on the host.
      local gone = fake.backend(name)
      gone.available = function()
        return false
      end
      package.loaded[mod] = gone
    end
  end)
  after_each(function()
    for _, name in ipairs(NAMES) do
      local mod = "sidekick-ultra.backends." .. name
      package.loaded[mod], package.preload[mod] = saved.loaded[name], saved.preload[name]
    end
    registry.reset()
  end)

  local function names()
    return vim.tbl_filter(function(name)
      return registry.backend(name) ~= nil
    end, NAMES)
  end

  local function use(...)
    for _, name in ipairs({ ... }) do
      package.loaded["sidekick-ultra.backends." .. name] = fake.backend(name)
    end
  end

  local function off()
    local ret = {}
    for _, name in ipairs(NAMES) do
      ret[name] = { enabled = false }
    end
    return ret
  end

  it("registers each enabled backend that is available, all four by default", function()
    use("herdr", "rex", "tmux", "zellij")
    sidekick.setup({})
    expect.equality(names(), { "herdr", "rex", "tmux", "zellij" })
  end)

  it("does not register an enabled backend whose binary is missing", function()
    use("herdr", "tmux")
    sidekick.setup({})
    expect.equality(names(), { "herdr", "tmux" })
  end)

  it("never requires a disabled backend", function()
    for _, name in ipairs(NAMES) do
      package.loaded["sidekick-ultra.backends." .. name] = nil
      package.preload["sidekick-ultra.backends." .. name] = function()
        error(name .. " must not be required")
      end
    end
    sidekick.setup(off())
    expect.equality(names(), {})
  end)

  it("registers only the enabled ones when others are disabled", function()
    use("rex", "tmux", "zellij")
    sidekick.setup({ herdr = { enabled = false }, tmux = { enabled = false } })
    expect.equality(names(), { "rex", "zellij" })
  end)

  it("raises an error naming the key path for an invalid option, and registers nothing", function()
    use("herdr")
    local ok, err = pcall(sidekick.setup, { rex = { server = 1 } })
    expect.equality(ok, false)
    expect.equality(err:find("rex.server", 1, true) ~= nil, true)
    expect.equality(names(), {})
    ok, err = pcall(sidekick.setup, { tmux = { socket = "" } })
    expect.equality(ok, false)
    expect.equality(err:find("tmux.socket", 1, true) ~= nil, true)
  end)

  it("applies tool, prompt and context configuration", function()
    fake.reset({ mine = { cmd = { "/bin/sh" }, location = "claude" } }, {
      prompts = { greet = "hello {who}", fix = false },
      context = {
        who = function()
          return "world"
        end,
      },
    })
    local cap = notify.capture()
    expect.equality(require("sidekick-ultra.tools").get("mine").location, "claude")
    expect.equality(sidekick.render({ prompt = "greet" }), "hello world")
    local _, err = sidekick.render({ prompt = "fix" })
    cap.restore()
    expect.equality(err.id, "unknown_prompt")
    expect.equality(cap.ids(), { "unknown_prompt" })
  end)

  it("detaches every attached session through the normal path when called again", function()
    fake.reset({ claude = { cmd = fake.INSTALLED } })
    local events = {}
    local group = vim.api.nvim_create_augroup("sku-spec-setup-events", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = registry.DETACH,
      callback = function(ev)
        table.insert(events, ev.data.id)
      end,
    })
    registry.attach(fake.session("herdr", "claude"))
    vim.wait(50, function()
      return false
    end)
    expect.equality(#require("sidekick-ultra.status").cli(), 1)
    sidekick.setup(off())
    vim.wait(1000, function()
      return #events > 0
    end)
    vim.api.nvim_del_augroup_by_id(group)
    expect.equality(events, { "herdr:claude1" })
    expect.equality(registry.attached(), {})
    expect.equality(require("sidekick-ultra.watch").active(), false)
    expect.equality(require("sidekick-ultra.status").cli(), {})
  end)

  it("exposes the actions on the module", function()
    for _, name in ipairs({ "send", "prompt", "select", "focus", "close", "render" }) do
      expect.equality(type(sidekick[name]), "function")
    end
  end)
end)
