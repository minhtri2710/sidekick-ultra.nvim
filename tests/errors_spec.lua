local errors = require("sidekick-ultra.errors")
local notify = require("tests.helpers.notify")

local expect = MiniTest.expect

describe("errors", function()
  local cap
  before_each(function()
    cap = notify.capture()
  end)
  after_each(function()
    cap.restore()
  end)

  it("knows exactly the documented ids", function()
    local expected = {
      "backend_error",
      "duplicate_session",
      "incomplete_command",
      "invalid_args",
      "invalid_command",
      "no_match",
      "not_in_mux",
      "not_installed",
      "nothing_to_send",
      "render_failed",
      "session_blocked",
      "status_unreadable",
      "unknown_context",
      "unknown_prompt",
    }
    local got = vim.tbl_keys(errors.ids)
    table.sort(got)
    expect.equality(got, expected)
  end)

  it("builds structured values and rejects unknown ids", function()
    local err = errors.new("backend_error", "boom", { backend = "herdr", cmd = "pane list", code = 1 })
    expect.equality(err, { id = "backend_error", msg = "boom", backend = "herdr", cmd = "pane list", code = 1 })
    expect.error(function()
      errors.new("nope", "x")
    end)
  end)

  it("notifies with the plugin title and the id", function()
    errors.notify(errors.new("not_in_mux", "m"))
    expect.equality(cap.calls[1].title, "sidekick-ultra")
    expect.equality(cap.calls[1].id, "not_in_mux")
    expect.equality(cap.calls[1].level, vim.log.levels.ERROR)
  end)

  it("reports no_match and nothing_to_send as warnings", function()
    errors.notify(errors.new("no_match", "m"))
    errors.notify(errors.new("nothing_to_send", "m"))
    expect.equality(cap.calls[1].level, vim.log.levels.WARN)
    expect.equality(cap.calls[2].level, vim.log.levels.WARN)
  end)

  it("sends info messages without an id", function()
    errors.info("hello")
    expect.equality(cap.calls[1].level, vim.log.levels.INFO)
    expect.equality(cap.calls[1].id, nil)
  end)
end)
