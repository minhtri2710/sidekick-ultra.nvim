local fake = require("tests.helpers.fake")
local notify = require("tests.helpers.notify")
local registry = require("sidekick-ultra.registry")
local sidekick = require("sidekick-ultra")

local expect = MiniTest.expect

describe("setup", function()
  local saved
  before_each(function()
    saved = {
      herdr = package.loaded["sidekick-ultra.backends.herdr"],
      rex = package.loaded["sidekick-ultra.backends.rex"],
      herdr_preload = package.preload["sidekick-ultra.backends.herdr"],
      rex_preload = package.preload["sidekick-ultra.backends.rex"],
    }
    package.loaded["sidekick-ultra.backends.herdr"] = nil
    package.loaded["sidekick-ultra.backends.rex"] = nil
  end)
  after_each(function()
    package.loaded["sidekick-ultra.backends.herdr"] = saved.herdr
    package.loaded["sidekick-ultra.backends.rex"] = saved.rex
    package.preload["sidekick-ultra.backends.herdr"] = saved.herdr_preload
    package.preload["sidekick-ultra.backends.rex"] = saved.rex_preload
    registry.reset()
  end)

  local function names()
    return vim.tbl_filter(function(name)
      return registry.backend(name) ~= nil
    end, { "herdr", "rex" })
  end

  it("registers each enabled backend that is available", function()
    package.loaded["sidekick-ultra.backends.herdr"] = fake.backend("herdr")
    package.loaded["sidekick-ultra.backends.rex"] = fake.backend("rex")
    sidekick.setup({})
    expect.equality(names(), { "herdr", "rex" })
  end)

  it("does not register an enabled backend whose binary is missing", function()
    local rex = fake.backend("rex")
    rex.available = function()
      return false
    end
    package.loaded["sidekick-ultra.backends.herdr"] = fake.backend("herdr")
    package.loaded["sidekick-ultra.backends.rex"] = rex
    sidekick.setup({})
    expect.equality(names(), { "herdr" })
  end)

  it("never requires a disabled backend", function()
    package.preload["sidekick-ultra.backends.herdr"] = function()
      error("herdr must not be required")
    end
    package.preload["sidekick-ultra.backends.rex"] = function()
      error("rex must not be required")
    end
    sidekick.setup({ herdr = { enabled = false }, rex = { enabled = false } })
    expect.equality(names(), {})
  end)

  it("registers only the enabled one when one is disabled", function()
    package.loaded["sidekick-ultra.backends.rex"] = fake.backend("rex")
    sidekick.setup({ herdr = { enabled = false } })
    expect.equality(names(), { "rex" })
  end)

  it("raises an error naming the key path for an invalid option, and registers nothing", function()
    package.loaded["sidekick-ultra.backends.herdr"] = fake.backend("herdr")
    local ok, err = pcall(sidekick.setup, { rex = { server = 1 } })
    expect.equality(ok, false)
    expect.equality(err:find("rex.server", 1, true) ~= nil, true)
    expect.equality(names(), {})
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
    sidekick.setup({ herdr = { enabled = false }, rex = { enabled = false } })
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
