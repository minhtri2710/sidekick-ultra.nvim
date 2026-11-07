local errors = require("sidekick-ultra.errors")
local fake = require("tests.helpers.fake")
local notify = require("tests.helpers.notify")
local registry = require("sidekick-ultra.registry")
local target = require("sidekick-ultra.target")
local ui = require("tests.helpers.ui")

local expect = MiniTest.expect

local OTHER_DIR = "/tmp/sku-other-dir"

---@param states sidekick_ultra.State[]
---@return string[]
local function names(states)
  return vim.tbl_map(function(s)
    return s.session and s.session.id or s.name
  end, states)
end

---Register a backend that lists a claude and a codex session, and attach both.
local function two_attached()
  registry.register(fake.backend("herdr", {
    sessions = { fake.session("herdr", "claude", 1), fake.session("herdr", "codex", 1) },
  }))
  for _, s in ipairs(registry.discover()) do
    registry.attach(s)
  end
end

describe("target", function()
  local cap, pick
  before_each(function()
    fake.reset({
      claude = { cmd = fake.INSTALLED },
      codex = { cmd = fake.INSTALLED },
      ghost = { cmd = { "/nonexistent/sku-ghost" }, url = "https://example.invalid/ghost" },
    })
    cap = notify.capture()
    pick = ui.capture()
  end)
  after_each(function()
    cap.restore()
    pick.restore()
    registry.reset()
  end)

  describe("states", function()
    it("lists every discovered session and every configured tool, even when a session of it exists", function()
      registry.register(fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } }))
      local states = target.states()
      expect.equality(names(states), { "herdr:claude1", "claude", "codex", "ghost" })
      local by = {}
      for _, s in ipairs(states) do
        by[s.session and s.session.id or s.name] = s
      end
      expect.equality(by["herdr:claude1"].started, true)
      expect.equality(by["herdr:claude1"].installed, true)
      expect.equality(by.claude.started, false)
      expect.equality(by.ghost.installed, false)
      expect.equality(by.codex.installed, true)
    end)

    it("marks attached sessions", function()
      local b = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
      registry.register(b)
      registry.attach(registry.discover()[1])
      expect.equality(target.states({ attached = true })[1].session.id, "herdr:claude1")
      expect.equality(#target.states({ attached = true }), 1)
    end)

    it("discovers once, and reports a failing backend once, when an attached session fails its check", function()
      local b = fake.backend("herdr", { list_err = errors.new("backend_error", "x") })
      registry.register(b)
      local s = fake.session("herdr", "claude")
      registry.attach(s)
      s.proc_name = "someone-else"
      expect.equality({ #target.states(), #b.of("list"), cap.ids() }, { 3, 1, { "backend_error" } })
    end)

    it("sorts installed first, then no-session or same-cwd, then started, then name, then id", function()
      registry.register(fake.backend("herdr", {
        sessions = {
          fake.session("herdr", "codex", 2),
          fake.session("herdr", "claude", 1, { cwd = OTHER_DIR }),
          fake.session("herdr", "codex", 1),
          fake.session("herdr", "ghost", 1),
        },
      }))
      expect.equality(
        names(target.states()),
        { "herdr:codex1", "herdr:codex2", "herdr:ghost1", "claude", "codex", "herdr:claude1", "ghost" }
      )
    end)
  end)

  describe("filters", function()
    local function setup_states()
      registry.register(fake.backend("herdr", {
        sessions = {
          fake.session("herdr", "claude", 1),
          fake.session("herdr", "codex", 1, { cwd = OTHER_DIR }),
        },
      }))
      registry.register(fake.backend("rex", { sessions = { fake.session("rex", "claude", 1) } }))
      registry.attach(registry.discover()[1])
    end

    it("filters by name, session id, backend, started, installed, cwd and attached, combined with AND", function()
      setup_states()
      expect.equality(names(target.states({ name = "codex" })), { "codex", "herdr:codex1" })
      expect.equality(names(target.states({ session = "rex:claude1" })), { "rex:claude1" })
      expect.equality(names(target.states({ backend = "herdr" })), { "herdr:claude1", "herdr:codex1" })
      expect.equality(names(target.states({ started = true, cwd = true })), { "herdr:claude1", "rex:claude1" })
      expect.equality(names(target.states({ installed = false })), { "ghost" })
      expect.equality(names(target.states({ attached = true })), { "herdr:claude1" })
      expect.equality(names(target.states({ started = true, name = "claude", backend = "rex" })), { "rex:claude1" })
      expect.equality(names(target.states({ cwd = false })), { "herdr:codex1" })
    end)
  end)

  describe("pick", function()
    local function state(name)
      return { name = name, tool = {}, installed = true, started = false, attached = false, cwd = true }
    end

    it("warns no_match and stops on zero states", function()
      local called = false
      target.pick({}, { auto = true }, function()
        called = true
      end)
      expect.equality({ called, cap.ids() }, { false, { "no_match" } })
      expect.equality(#pick.selects, 0)
    end)

    it("chooses the only match without UI when auto", function()
      local chosen
      target.pick({ state("a") }, { auto = true }, function(s)
        chosen = s.name
      end)
      expect.equality({ chosen, #pick.selects }, { "a", 0 })
    end)

    it("opens the UI for one match without auto, and for several matches", function()
      local chosen
      pick.choose = function(items)
        return items[2]
      end
      target.pick({ state("a") }, {}, function() end)
      target.pick({ state("a"), state("b") }, { auto = true }, function(s)
        chosen = s.name
      end)
      expect.equality({ #pick.selects, chosen }, { 2, "b" })
    end)

    it("does nothing when cancelled", function()
      pick.choose = function() end
      local called = false
      target.pick({ state("a"), state("b") }, {}, function()
        called = true
      end)
      expect.equality(called, false)
    end)

    it("labels sessions with tool, backend and shortened cwd, and tools with just the name", function()
      local session = fake.session("herdr", "claude", 1, { cwd = vim.env.HOME .. "/project" })
      registry.register(fake.backend("herdr", { sessions = { session } }))
      local started_state = target.states({ started = true })[1]
      local tool_state = target.states({ started = false, name = "claude" })[1]
      target.pick({ started_state, tool_state }, {}, function() end)
      local format_item = pick.selects[1].opts.format_item
      local started = format_item(started_state)
      expect.equality(started:find("claude [herdr] ~/project", 1, true) ~= nil, true)
      local tool = format_item(tool_state)
      expect.equality(tool:find("claude", 1, true) ~= nil and tool:find("[", 1, true) == nil, true)
    end)
  end)

  describe("attach_state", function()
    it("refuses a missing tool with not_installed and opens its url", function()
      local state = target.states({ name = "ghost" })[1]
      expect.equality(target.attach_state(state), nil)
      expect.equality(cap.ids()[1], "not_installed")
      expect.equality(pick.opened, { "https://example.invalid/ghost" })
    end)

    it("reports a failing url open without crashing", function()
      vim.ui.open = function()
        return nil, "no opener"
      end
      local state = target.states({ name = "ghost" })[1]
      expect.equality(target.attach_state(state), nil)
      expect.equality(#cap.calls, 2)
      expect.equality(cap.calls[1].id, "not_installed")
      expect.equality({ cap.calls[2].id, cap.calls[2].level }, { nil, vim.log.levels.WARN })
    end)

    it("attaches a started session once, with one info message", function()
      registry.register(fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } }))
      local state = target.states({ started = true })[1]
      expect.equality(target.attach_state(state).id, "herdr:claude1")
      expect.equality(#cap.calls, 1)
      expect.equality(cap.calls[1].level, vim.log.levels.INFO)
      expect.equality(target.attach_state(state).id, "herdr:claude1")
      expect.equality(#cap.calls, 1)
      expect.equality(#registry.attached(), 1)
    end)

    it("starts a not-started tool through the backend inside the mux, then attaches it, without focusing", function()
      local b = fake.backend("herdr", { is_inside = true })
      registry.register(b)
      local session = target.attach_state(target.states({ name = "codex" })[1])
      expect.equality(session.id, "herdr:codexnew1")
      expect.equality({ #b.of("start"), b.of("focus") }, { 1, {} })
      expect.equality(registry.attached()[1].id, "herdr:codexnew1")
    end)

    it("reports a started tool as started and an existing session as not", function()
      local b = fake.backend("herdr", { is_inside = true, sessions = { fake.session("herdr", "claude") } })
      registry.register(b)
      local _, started = target.attach_state(target.states({ name = "codex" })[1])
      local _, existing = target.attach_state(target.states({ started = true })[1])
      expect.equality({ started, existing }, { true, false })
    end)

    it("refuses to start with not_in_mux and creates nothing", function()
      local b = fake.backend("herdr", { is_inside = false })
      registry.register(b)
      expect.equality(target.attach_state(target.states({ name = "codex" })[1]), nil)
      expect.equality({ cap.ids(), #b.of("start"), #registry.attached() }, { { "not_in_mux" }, 0, 0 })
    end)

    it("refuses a session whose backend a later setup removed while the picker was open", function()
      registry.register(fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } }))
      local state = target.states({ started = true })[1]
      registry.reset()
      expect.equality(target.attach_state(state), nil)
      expect.equality({ cap.ids(), registry.attached() }, { { "backend_error" }, {} })
    end)

    it("refuses a session and a tool that a later setup removed from the configuration", function()
      local b = fake.backend("herdr", { is_inside = true, sessions = { fake.session("herdr", "claude") } })
      registry.register(b)
      local session_state, tool_state = target.states({ started = true })[1], target.states({ name = "codex" })[1]
      fake.reset({})
      registry.register(b)
      b.calls = {}
      expect.equality(target.attach_state(session_state), nil)
      expect.equality(target.attach_state(tool_state), nil)
      expect.equality({ cap.ids(), registry.attached(), b.calls }, { { "no_match", "no_match" }, {}, {} })
    end)

    it("attaches again a session listed as attached that a setup detached", function()
      two_attached()
      local state = target.states({ name = "claude", started = true })[1]
      local b = registry.backend("herdr")
      registry.reset()
      registry.register(b)
      expect.equality(target.attach_state(state).id, "herdr:claude1")
      expect.equality({ cap.ids(), #registry.attached() }, { {}, 1 })
    end)

    it("decides installed and the url from the tool's current spec, not the one listed", function()
      local b = fake.backend("herdr", { is_inside = true, sessions = { fake.session("herdr", "claude") } })
      registry.register(b)
      local was_installed = target.states({ name = "claude", started = false })[1]
      local was_missing = target.states({ name = "ghost" })[1]
      local was_running = target.states({ name = "claude", started = true })[1]
      fake.reset({
        claude = { cmd = { "/nonexistent/sku-gone" }, url = "https://example.invalid/claude" },
        ghost = { cmd = fake.INSTALLED, env = { SKU_SPEC_ENV = "new" } },
      })
      registry.register(b)
      expect.equality(target.attach_state(was_installed), nil)
      expect.equality(
        { cap.ids(), pick.opened, #b.of("start") },
        { { "not_installed" }, { "https://example.invalid/claude" }, 0 }
      )
      expect.equality(target.attach_state(was_missing).id, "herdr:ghostnew1")
      expect.equality(b.of("start")[1][3].env, { SKU_SPEC_ENV = "new" })
      -- A session that is already running needs no binary here, so a missing one does not refuse it.
      expect.equality(target.attach_state(was_running).id, "herdr:claude1")
      expect.equality(cap.ids(), { "not_installed" })
    end)

    it("reports a failing start", function()
      registry.register(fake.backend("herdr", { is_inside = true, start_err = errors.new("backend_error", "x") }))
      expect.equality(target.attach_state(target.states({ name = "codex" })[1]), nil)
      expect.equality(cap.ids(), { "backend_error" })
    end)
  end)

  describe("with_target", function()
    ---The id of the session the callback got, and its tool.
    local function run(filter)
      local got
      target.with_target(filter, function(state)
        got = { state.session.id, state.tool.name }
      end)
      return got
    end

    it("picks over all matching states and attaches when none is attached", function()
      registry.register(fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } }))
      pick.choose = function(items)
        return items[1]
      end
      expect.equality(run({}), { "herdr:claude1", "claude" })
      expect.equality(#pick.selects, 1)
      expect.equality(#registry.attached(), 1)
    end)

    it("tells the callback whether this call started the tool", function()
      local b = fake.backend("herdr", {
        is_inside = true,
        sessions = { fake.session("herdr", "claude") },
      })
      registry.register(b)
      pick.choose = function(items)
        return items[1]
      end
      local got = {}
      local function record(state, started)
        table.insert(got, { state.session.id, started or false })
      end
      target.with_target({ name = "codex" }, record)
      target.with_target({ name = "claude" }, record)
      target.with_target({ name = "claude" }, record)
      expect.equality(got, { { "herdr:codexnew1", true }, { "herdr:claude1", false }, { "herdr:claude1", false } })
      expect.equality(b.of("focus"), {})
    end)

    it("reports no_match when the filter leaves no state", function()
      expect.equality(run({ name = "nope" }), nil)
      expect.equality(cap.ids(), { "no_match" })
    end)

    it("acts on the only attached match without UI", function()
      registry.register(fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } }))
      registry.attach(registry.discover()[1])
      expect.equality(run({}), { "herdr:claude1", "claude" })
      expect.equality(#pick.selects, 0)
    end)

    it("picks among several attached matches", function()
      two_attached()
      pick.choose = function(items)
        return items[2]
      end
      expect.equality(run({}), { "herdr:codex1", "codex" })
      expect.equality(#pick.selects, 1)
      expect.equality(#pick.selects[1].items, 2)
    end)

    it("narrows the attached matches with the filter", function()
      two_attached()
      expect.equality(run({ name = "codex" }), { "herdr:codex1", "codex" })
      expect.equality(#pick.selects, 0)
    end)

    it("does not reach the callback with a session that a setup detached while the pick was open", function()
      two_attached()
      local b = registry.backend("herdr")
      pick.choose = function(items)
        fake.reset({ claude = { cmd = fake.INSTALLED }, codex = { cmd = fake.INSTALLED } })
        registry.register(b)
        return items[2]
      end
      expect.equality(run({}), nil)
      expect.equality({ cap.ids(), registry.attached() }, { { "no_match" }, {} })
    end)
  end)

  describe("with_attached", function()
    local function run(filter, opts)
      local got = {}
      target.with_attached(filter, opts or {}, function(state)
        table.insert(got, state.session.id)
      end)
      return got
    end

    it("passes every attached match without UI", function()
      two_attached()
      expect.equality(run(), { "herdr:claude1", "herdr:codex1" })
      expect.equality(run({ name = "codex" }), { "herdr:codex1" })
      expect.equality(#pick.selects, 0)
    end)

    it("reports no_match when no attached session matches, one or all", function()
      expect.equality(run(), {})
      expect.equality(run({}, { one = true }), {})
      two_attached()
      expect.equality(run({ name = "ghost" }), {})
      expect.equality(cap.ids(), { "no_match", "no_match", "no_match" })
    end)

    it("checks that the attached sessions still run first", function()
      local b = fake.backend("herdr")
      registry.register(b)
      local s = fake.session("herdr", "claude")
      registry.attach(s)
      s.proc_name = "gone"
      expect.equality({ run({}, { one = true }), cap.ids(), #b.of("list") }, { {}, { "no_match" }, 1 })
    end)

    it("with one picks among several attached matches and passes only that one", function()
      two_attached()
      pick.choose = function(items)
        return items[2]
      end
      expect.equality(run({}, { one = true }), { "herdr:codex1" })
      expect.equality(#pick.selects[1].items, 2)
    end)

    it("with one does not reach the callback with a session that a setup detached while the pick was open", function()
      two_attached()
      local b = registry.backend("herdr")
      pick.choose = function(items)
        fake.reset({ claude = { cmd = fake.INSTALLED }, codex = { cmd = fake.INSTALLED } })
        registry.register(b)
        return items[2]
      end
      expect.equality(run({}, { one = true }), {})
      expect.equality({ cap.ids(), registry.attached() }, { { "no_match" }, {} })
    end)
  end)
end)
