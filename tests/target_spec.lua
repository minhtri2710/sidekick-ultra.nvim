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
      registry.register(fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } }))
      local started = target.label(target.states({ started = true })[1])
      expect.equality(
        started:find("claude [herdr] " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~"), 1, true) ~= nil,
        true
      )
      local tool = target.label(target.states({ started = false, name = "claude" })[1])
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

    it("reports a failing start", function()
      registry.register(fake.backend("herdr", { is_inside = true, start_err = errors.new("backend_error", "x") }))
      expect.equality(target.attach_state(target.states({ name = "codex" })[1]), nil)
      expect.equality(cap.ids(), { "backend_error" })
    end)
  end)

  describe("with_target", function()
    local function run(opts)
      local got
      target.with_target(opts, function(sessions)
        got = vim.tbl_map(function(s)
          return s.id
        end, sessions)
      end)
      return got
    end

    local function two_attached()
      registry.register(fake.backend("herdr", {
        sessions = { fake.session("herdr", "claude", 1), fake.session("herdr", "codex", 1) },
      }))
      for _, s in ipairs(registry.discover()) do
        registry.attach(s)
      end
    end

    it("picks over all matching states and attaches when none is attached", function()
      registry.register(fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } }))
      pick.choose = function(items)
        return items[1]
      end
      expect.equality(run({ attach = true }), { "herdr:claude1" })
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
      local flags = {}
      local function record(_, started)
        table.insert(flags, started or false)
      end
      target.with_target({ attach = true, filter = { name = "codex" } }, record)
      target.with_target({ attach = true, filter = { name = "claude" } }, record)
      target.with_target({ filter = { name = "claude" } }, record)
      expect.equality(flags, { true, false, false })
      expect.equality(b.of("focus"), {})
    end)

    it("checks that the attached sessions still run before it chooses among them", function()
      local b = fake.backend("herdr")
      registry.register(b)
      local s = fake.session("herdr", "claude")
      registry.attach(s)
      s.proc_name = "gone"
      expect.equality(run({}), nil)
      expect.equality({ cap.ids(), #b.of("list") }, { { "no_match" }, 1 })
    end)

    it("reports no_match when nothing is attached and the action may not attach", function()
      expect.equality(run({}), nil)
      expect.equality(cap.ids(), { "no_match" })
    end)

    it("reports no_match when the filter leaves no state", function()
      expect.equality(run({ attach = true, filter = { name = "nope" } }), nil)
      expect.equality(cap.ids(), { "no_match" })
    end)

    it("acts on the only attached match without UI", function()
      registry.register(fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } }))
      registry.attach(registry.discover()[1])
      expect.equality(run({ attach = true }), { "herdr:claude1" })
      expect.equality(#pick.selects, 0)
    end)

    it("picks among several attached matches unless the action is 'all'", function()
      two_attached()
      pick.choose = function(items)
        return items[2]
      end
      expect.equality(run({ attach = true }), { "herdr:codex1" })
      expect.equality(#pick.selects, 1)
      expect.equality(#pick.selects[1].items, 2)
      expect.equality(run({ all = true }), { "herdr:claude1", "herdr:codex1" })
      expect.equality(#pick.selects, 1)
    end)

    it("narrows the attached matches with the filter", function()
      two_attached()
      expect.equality(run({ filter = { name = "codex" } }), { "herdr:codex1" })
      expect.equality(#pick.selects, 0)
    end)
  end)
end)
