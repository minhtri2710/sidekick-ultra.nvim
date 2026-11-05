local fake = require("tests.helpers.fake")
local notify = require("tests.helpers.notify")
local registry = require("sidekick-ultra.registry")

local expect = MiniTest.expect

describe("registry", function()
  local cap, events
  before_each(function()
    fake.reset({ claude = { cmd = fake.INSTALLED }, codex = { cmd = fake.INSTALLED } })
    cap = notify.capture()
    events = {}
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("sku-spec-events", { clear = true }),
      pattern = { registry.ATTACH, registry.DETACH },
      callback = function(ev)
        table.insert(events, { ev.match, ev.data.id })
      end,
    })
  end)
  after_each(function()
    cap.restore()
    vim.api.nvim_del_augroup_by_name("sku-spec-events")
    registry.reset()
    vim.env.TERM_PROGRAM = nil
  end)

  local function settle()
    vim.wait(50, function()
      return false
    end)
  end

  describe("backends", function()
    it("rejects a backend that does not match the contract", function()
      expect.error(function()
        registry.register({ name = "x" })
      end)
      expect.error(function()
        registry.register("x")
      end)
    end)

    it("rejects a second backend with the same name", function()
      registry.register(fake.backend("herdr"))
      expect.error(function()
        registry.register(fake.backend("herdr"))
      end)
    end)

    it("finds a backend by name", function()
      local b = fake.backend("herdr")
      registry.register(b)
      expect.equality(registry.backend("herdr") == b, true)
      expect.equality(registry.backend("rex"), nil)
    end)
  end)

  describe("sid", function()
    it("is the tool plus the first 16 - len(tool) hex characters of the sha256 of the cwd", function()
      local sid = registry.sid("claude", "/tmp/sku-dir")
      expect.equality(sid, "claude " .. vim.fn.sha256("/tmp/sku-dir"):sub(1, 10))
      expect.equality(#sid, #"claude " + 16 - #"claude")
    end)

    it("normalizes the cwd and differs per directory", function()
      expect.equality(registry.sid("codex", "/tmp/a/"), registry.sid("codex", "/tmp/a"))
      expect.no_equality(registry.sid("codex", "/tmp/a"), registry.sid("codex", "/tmp/b"))
    end)
  end)

  describe("discover", function()
    it("collects the sessions of every backend and sets sid", function()
      local a = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
      local b = fake.backend("rex", { sessions = { fake.session("rex", "codex") } })
      registry.register(a)
      registry.register(b)
      local sessions = registry.discover()
      expect.equality(
        vim.tbl_map(function(s)
          return s.id
        end, sessions),
        { "herdr:claude1", "rex:codex1" }
      )
      expect.equality(sessions[1].sid, registry.sid("claude", vim.fn.getcwd()))
      expect.equality(a.calls[1][1], "list")
      expect.equality(vim.tbl_contains(a.calls[1][2], "claude"), true)
    end)

    it("reports duplicate_session once and keeps the first", function()
      local first = fake.session("herdr", "claude", 1, { state = "idle" })
      local second = fake.session("herdr", "claude", 1, { state = "working" })
      registry.register(fake.backend("herdr", { sessions = { first, second } }))
      local sessions = registry.discover()
      expect.equality(#sessions, 1)
      expect.equality(sessions[1].state, "idle")
      expect.equality(cap.ids(), { "duplicate_session" })
    end)

    it("reports a duplicate id across backends", function()
      registry.register(fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } }))
      registry.register(fake.backend("rex", { sessions = { fake.session("herdr", "claude") } }))
      expect.equality(#registry.discover(), 1)
      expect.equality(cap.ids(), { "duplicate_session" })
    end)

    it("isolates a backend whose list fails: one error, the other backend still lists", function()
      local err = require("sidekick-ultra.errors").new("backend_error", "x", { backend = "herdr", cmd = "pane list" })
      registry.register(fake.backend("herdr", { list_err = err }))
      registry.register(fake.backend("rex", { sessions = { fake.session("rex", "codex") } }))
      local sessions = registry.discover()
      expect.equality(#sessions, 1)
      expect.equality(sessions[1].id, "rex:codex1")
      expect.equality(cap.ids(), { "backend_error" })
    end)

    it("turns a thrown list into backend_error", function()
      local b = fake.backend("herdr")
      b.list = function()
        error("boom")
      end
      registry.register(b)
      expect.equality(registry.discover(), {})
      expect.equality(cap.ids(), { "backend_error" })
    end)
  end)

  describe("attached set", function()
    it("attaches once, fires one attach event, and detaches", function()
      local s = fake.session("herdr", "claude")
      expect.equality(registry.attach(s), true)
      expect.equality(registry.attach(s), false)
      settle()
      expect.equality(events, { { registry.ATTACH, "herdr:claude1" } })
      expect.equality(registry.detach("herdr:claude1") == s, true)
      expect.equality(registry.detach("herdr:claude1"), nil)
      settle()
      expect.equality(events[2], { registry.DETACH, "herdr:claude1" })
      expect.equality(#events, 2)
      expect.equality(registry.attached(), {})
    end)

    it("detaches an attached id that is no longer listed, with the event and no message", function()
      local b = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
      registry.register(b)
      registry.attach(registry.discover()[1])
      b.sessions = {}
      registry.discover()
      expect.equality(registry.attached(), {})
      settle()
      expect.equality(events[#events], { registry.DETACH, "herdr:claude1" })
      expect.equality(cap.calls, {})
    end)

    it("keeps attached sessions of a backend that failed to list", function()
      local b = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
      registry.register(b)
      registry.attach(registry.discover()[1])
      b.list_err = require("sidekick-ultra.errors").new("backend_error", "x")
      registry.discover()
      expect.equality(#registry.attached(), 1)
    end)

    it("replaces an attached entry with the fresh object and keeps it attached", function()
      local b = fake.backend("herdr", { sessions = { fake.session("herdr", "claude", 1, { state = "idle" }) } })
      registry.register(b)
      registry.attach(registry.discover()[1])
      b.sessions = { fake.session("herdr", "claude", 1, { state = "working" }) }
      registry.discover()
      local attached = registry.attached()
      expect.equality(#attached, 1)
      expect.equality(attached[1].state, "working")
      settle()
      expect.equality(#events, 1)
    end)

    it("drops attached sessions that stopped running", function()
      local s = fake.session("herdr", "claude")
      registry.attach(s)
      s.proc_name = "someone-else"
      expect.equality(registry.attached(), {})
      settle()
      expect.equality(events[#events], { registry.DETACH, "herdr:claude1" })
    end)

    it("returns the attached sessions sorted by id", function()
      registry.attach(fake.session("rex", "codex"))
      registry.attach(fake.session("herdr", "claude"))
      expect.equality(
        vim.tbl_map(function(s)
          return s.id
        end, registry.attached()),
        { "herdr:claude1", "rex:codex1" }
      )
    end)
  end)

  describe("is_running", function()
    it("needs the recorded pid to exist with the recorded name", function()
      local s = fake.session("herdr", "claude")
      expect.equality(registry.is_running(s), true)
      expect.equality(registry.is_running(vim.tbl_extend("force", s, { proc_name = "other" })), false)
      expect.equality(registry.is_running(vim.tbl_extend("force", s, { pid = 2 ^ 22 + 12345 })), false)
    end)
  end)

  describe("start backend selection", function()
    local function select(inside_names, term)
      registry.reset()
      for _, name in ipairs({ "herdr", "rex" }) do
        registry.register(fake.backend(name, { is_inside = vim.tbl_contains(inside_names, name) }))
      end
      vim.env.TERM_PROGRAM = term
      local backend, err = registry.start_backend()
      return backend and backend.name, err and err.id
    end

    it("uses the only backend that is inside", function()
      expect.equality({ select({ "rex" }, nil) }, { "rex" })
      expect.equality({ select({ "rex" }, "herdr") }, { "rex" })
    end)

    it("uses the one named by TERM_PROGRAM when both are inside", function()
      expect.equality({ select({ "herdr", "rex" }, "rex") }, { "rex" })
    end)

    it("refuses when both are inside and TERM_PROGRAM names neither", function()
      expect.equality({ select({ "herdr", "rex" }, "iTerm.app") }, { nil, "not_in_mux" })
    end)

    it("refuses when both are inside and TERM_PROGRAM is unset", function()
      expect.equality({ select({ "herdr", "rex" }, nil) }, { nil, "not_in_mux" })
    end)
  end)

  describe("start", function()
    it("passes cwd and env to the selected backend and sets sid", function()
      local b = fake.backend("herdr", { is_inside = true })
      registry.register(b)
      local tool = require("sidekick-ultra.tools").get("claude")
      tool.env = { A = "b" }
      local session = registry.start(tool)
      expect.equality(b.calls[1][1], "start")
      expect.equality(b.calls[1][3], { cwd = vim.fn.getcwd(), env = { A = "b" } })
      expect.equality(session.sid, registry.sid("claude", session.cwd))
    end)

    it("focuses the new session once through its backend, after the start", function()
      local b = fake.backend("herdr", { is_inside = true })
      registry.register(b)
      local session = registry.start(require("sidekick-ultra.tools").get("claude"))
      expect.equality(
        vim.tbl_map(function(call)
          return { call[1], call[2] }
        end, vim.list_slice(b.calls, 1, 2)),
        { { "start", "claude" }, { "focus", session.id } }
      )
      expect.equality(#b.calls, 2)
    end)

    it("does not focus with focus = false", function()
      local b = fake.backend("herdr", { is_inside = true })
      registry.register(b)
      expect.equality(registry.start(require("sidekick-ultra.tools").get("claude"), { focus = false }) ~= nil, true)
      expect.equality(b.of("focus"), {})
    end)

    it("notifies a focus refusal and still returns the session", function()
      local err = require("sidekick-ultra.errors").new("backend_error", "x")
      local b = fake.backend("herdr", { is_inside = true, fail = { focus = err } })
      registry.register(b)
      local session, got = registry.start(require("sidekick-ultra.tools").get("claude"))
      expect.equality({ session.id, got, cap.ids() }, { "herdr:claudenew1", nil, { "backend_error" } })
    end)

    it("creates nothing and returns not_in_mux outside a mux", function()
      local b = fake.backend("herdr", { is_inside = false })
      registry.register(b)
      local session, err = registry.start(require("sidekick-ultra.tools").get("claude"))
      expect.equality({ session, err.id }, { nil, "not_in_mux" })
      expect.equality({ b.of("start"), b.of("focus") }, { {}, {} })
    end)

    it("returns the backend error", function()
      local err = require("sidekick-ultra.errors").new("backend_error", "x")
      local b = fake.backend("herdr", { is_inside = true, start_err = err })
      registry.register(b)
      local session, got = registry.start(require("sidekick-ultra.tools").get("claude"))
      expect.equality({ session, got.id }, { nil, "backend_error" })
      expect.equality(b.of("focus"), {})
    end)
  end)
end)
