local fake = require("tests.helpers.fake")
local registry = require("sidekick-ultra.registry")
local status = require("sidekick-ultra.status")

local expect = MiniTest.expect

describe("status", function()
  local orig_now, now
  before_each(function()
    fake.reset({ claude = { cmd = fake.INSTALLED } })
    orig_now = vim.uv.now
    now = 1000
    vim.uv.now = function()
      return now
    end
  end)
  after_each(function()
    vim.uv.now = orig_now
    registry.reset()
  end)

  it("is empty with nothing attached", function()
    expect.equality(status.cli(), {})
  end)

  it("lists attached sessions with id, tool, cwd, backend and state, refreshed by the attach event", function()
    local s = fake.session("herdr", "claude", 1, { state = "working" })
    -- Prime a fresh cache first: only the attach event can then update it.
    expect.equality(status.cli(), {})
    registry.attach(s)
    fake.flush()
    expect.equality(status.cli(), {
      { id = "herdr:claude1", tool = "claude", cwd = s.cwd, backend = "herdr", state = "working" },
    })
  end)

  it("has a nil state when the backend reports none", function()
    local s = fake.session("rex", "claude")
    s.state = nil
    registry.attach(s)
    fake.flush()
    expect.equality(status.cli()[1].state, nil)
  end)

  it("refreshes on the detach event", function()
    registry.attach(fake.session("herdr", "claude"))
    fake.flush()
    expect.equality(#status.cli(), 1)
    registry.detach("herdr:claude1")
    fake.flush()
    expect.equality(status.cli(), {})
  end)

  it("checks nothing when an event refreshes it", function()
    local b = fake.backend("herdr")
    registry.register(b)
    local s = fake.session("herdr", "claude")
    s.proc_name = "gone"
    registry.attach(s)
    fake.flush()
    expect.equality(#status.cli(), 1)
    expect.equality(b.of("list"), {})
  end)

  it("serves the cache for 5 s, then refreshes and auto-detaches dead sessions", function()
    registry.register(fake.backend("herdr"))
    local s = fake.session("herdr", "claude")
    registry.attach(s)
    fake.flush()
    expect.equality(#status.cli(), 1)
    s.proc_name = "gone"
    now = now + 4000
    expect.equality(#status.cli(), 1)
    now = now + 2000
    expect.equality(status.cli(), {})
    expect.equality(registry.attached(), {})
  end)
end)
