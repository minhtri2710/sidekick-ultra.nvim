-- The fixtures in tests/fixtures/zellij follow the shapes the D8 probe printed from zellij 0.45.1. What is still
-- unverified is listed in UNVERIFIED.txt there.
local backend = require("sidekick-ultra.backend")
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")
local fake = require("tests.helpers.fake")
local notify = require("tests.helpers.notify")
local registry = require("sidekick-ultra.registry")
local tools = require("sidekick-ultra.tools")
local zellij = require("sidekick-ultra.backends.zellij")

local expect = MiniTest.expect

local TESTS = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local FIXTURES = TESTS .. "/fixtures/zellij/"
local STUB = TESTS .. "/bin/zellij"
local SECRET = "SECRET-TOKEN-xyz"

---@param name string file name inside tests/fixtures/zellij
---@return string
local function fixture(name)
  return table.concat(vim.fn.readfile(FIXTURES .. name), "\n")
end

---A pane list fixture, decoded, changed by `patch`, and encoded again.
---@param name string
---@param patch fun(panes: table[])
---@return string
local function patched(name, patch)
  local panes = vim.json.decode(fixture(name))
  patch(panes)
  return vim.json.encode(panes)
end

---The terminal pane with this id, not the plugin pane that shares it.
---@param panes table[]
---@param id integer
---@return table
local function terminal(panes, id)
  for _, pane in ipairs(panes) do
    if pane.id == id and not pane.is_plugin then
      return pane
    end
  end
  error("no terminal pane " .. id)
end

---@param stdout string
---@return table
local function ok(stdout)
  return { code = 0, stdout = stdout, stderr = "" }
end

---Replace `exec.run`. `routes` maps the arguments after the binary (joined by spaces) to a result table, stdout
---text, or a function(call number) returning either. A command without a route is recorded in `unexpected` and fails
---with exit 97.
---@param routes table<string, table|string|fun(n: integer): table|string>
local function record(routes)
  local rec = { calls = {}, subs = {}, unexpected = {}, orig = exec.run }
  local counts = {}
  exec.run = function(argv, opts)
    table.insert(rec.calls, { argv = argv, opts = opts })
    local sub = vim.list_slice(argv, 2)
    table.insert(rec.subs, sub)
    local key = table.concat(sub, " ")
    counts[key] = (counts[key] or 0) + 1
    local route = routes[key]
    if type(route) == "function" then
      route = route(counts[key])
    end
    if route == nil then
      table.insert(rec.unexpected, key)
      return { code = 97, stdout = "", stderr = "unexpected command" }
    end
    return type(route) == "string" and ok(route) or route
  end
  function rec.restore()
    exec.run = rec.orig
  end
  ---@return string[] the commands run, joined
  function rec.keys()
    return vim.tbl_map(function(sub)
      return table.concat(sub, " ")
    end, rec.subs)
  end
  return rec
end

local LIST_SESSIONS = "list-sessions -n -s"
local PANES_A = "--session skuA action list-panes --all --json --command --state"
local PANES_B = "--session skuB action list-panes --all --json --command --state"
local NOT_FOUND = { code = 1, stdout = "", stderr = "Session 'skuA' not found\n" }

---@param session string
---@return string
local function write_chars(session, pane, text)
  return ("--session %s action write-chars --pane-id %s -- %s"):format(session, pane, text)
end

describe("zellij backend", function()
  local rec, dir, bin
  local env = {}
  local VARS = { "ZELLIJ", "ZELLIJ_PANE_ID", "ZELLIJ_SESSION_NAME", "PATH" }

  ---@param patch? fun(session: table)
  ---@return sidekick_ultra.Session the claude pane (terminal_1) of session skuA
  local function claude(patch)
    local session = {
      id = "zellij:skuA:terminal_1",
      backend = "zellij",
      tool = "claude",
      cwd = "/tmp/sku-proj-a",
      proc_name = "claude",
      zellij_session = "skuA",
      pane = "terminal_1",
    }
    if patch then
      patch(session)
    end
    return session
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    bin = dir .. "/zellij"
    -- The same stub as tests/bin/zellij, so a call that escapes the seam leaves the marker minit checks.
    vim.fn.writefile(vim.fn.readfile(STUB), bin)
    vim.uv.fs_chmod(bin, 493)
    bin = vim.fn.exepath(bin)
    for _, var in ipairs(VARS) do
      env[var] = vim.env[var]
    end
    vim.env.PATH = dir .. ":" .. env.PATH
    vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID, vim.env.ZELLIJ_SESSION_NAME = nil, nil, nil
    fake.reset(
      { claude = { cmd = fake.INSTALLED }, codex = { cmd = fake.INSTALLED } },
      { zellij = { enabled = false } }
    )
  end)

  after_each(function()
    if rec then
      rec.restore()
      expect.equality(rec.unexpected, {})
      rec = nil
    end
    for _, var in ipairs(VARS) do
      vim.env[var] = env[var]
    end
    vim.fn.delete(dir, "rf")
  end)

  it("satisfies the backend contract", function()
    expect.equality(backend.check(zellij), true)
    expect.equality(zellij.name, "zellij")
  end)

  describe("available", function()
    it("reports the binary found on PATH", function()
      expect.equality({ zellij.available() }, { true, bin, "PATH" })
    end)

    it("is unavailable when zellij is not on PATH", function()
      vim.env.PATH = "/nonexistent-sku-path"
      expect.equality({ zellij.available() }, { false })
    end)
  end)

  describe("inside", function()
    local function inside(zellij_env, pane)
      vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID = zellij_env, pane
      return zellij.inside()
    end

    it("needs both ZELLIJ and ZELLIJ_PANE_ID set and non-empty", function()
      expect.equality(inside("0", "0"), true)
      expect.equality(inside(nil, "0"), false)
      expect.equality(inside("0", nil), false)
      expect.equality(inside("", "0"), false)
      expect.equality(inside("0", ""), false)
    end)
  end)

  describe("list", function()
    local function routes()
      return {
        [LIST_SESSIONS] = fixture("list_sessions.txt"),
        [PANES_A] = fixture("list_panes_a.json"),
        [PANES_B] = fixture("list_panes_b.json"),
      }
    end

    it("lists the sessions, then the panes of each session once, and keeps the panes that run a tool", function()
      rec = record(routes())
      local list, err = zellij.list(tools.all())
      expect.equality(err, nil)
      expect.equality(rec.keys(), { LIST_SESSIONS, PANES_A, PANES_B })
      expect.equality(rec.calls[1].argv[1], bin)
      expect.equality(list, {
        {
          id = "zellij:skuA:terminal_1",
          backend = "zellij",
          tool = "claude",
          cwd = "/tmp/sku-proj-a",
          proc_name = "claude",
          zellij_session = "skuA",
          pane = "terminal_1",
        },
        {
          id = "zellij:skuA:terminal_2",
          backend = "zellij",
          tool = "codex",
          cwd = "/tmp/sku-proj-b",
          proc_name = "codex",
          zellij_session = "skuA",
          pane = "terminal_2",
        },
        {
          id = "zellij:skuB:terminal_5",
          backend = "zellij",
          tool = "codex",
          cwd = "/tmp/sku-proj-c",
          proc_name = "codex",
          zellij_session = "skuB",
          pane = "terminal_5",
        },
      })
    end)

    it("lists only nvim's own session, without list-sessions, when nvim is inside zellij", function()
      vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID, vim.env.ZELLIJ_SESSION_NAME = "0", "0", "skuB"
      rec = record(routes())
      local list = zellij.list(tools.all())
      expect.equality(rec.keys(), { PANES_B })
      expect.equality(
        vim.tbl_map(function(s)
          return s.id
        end, list),
        { "zellij:skuB:terminal_5" }
      )
    end)

    it("takes the program from the basename of the first word of pane_command", function()
      local cases = {
        { "/usr/local/bin/claude", "claude" },
        { "claude", "claude" },
        { "  /opt/bin/claude --flag value", "claude" },
        { "/usr/local/bin/claudex", nil },
        { "/usr/local/bin/sh -c claude", nil },
      }
      for _, case in ipairs(cases) do
        rec = record({
          [LIST_SESSIONS] = "skuA\n",
          [PANES_A] = patched("list_panes_a.json", function(panes)
            terminal(panes, 1).pane_command = case[1]
            terminal(panes, 2).pane_command = nil
          end),
        })
        local list = zellij.list(tools.all())
        rec.restore()
        rec = nil
        local found = vim.tbl_filter(function(s)
          return s.pane == "terminal_1"
        end, list)
        expect.equality(found[1] and found[1].proc_name, case[2])
      end
    end)

    it("skips plugin panes, even one that carries a matching pane_command", function()
      rec = record({
        [LIST_SESSIONS] = "skuA\n",
        [PANES_A] = patched("list_panes_a.json", function(panes)
          for _, pane in ipairs(panes) do
            if pane.is_plugin then
              pane.pane_command = "/usr/local/bin/claude"
              pane.pane_cwd = "/tmp/sku-plugin"
            end
          end
          terminal(panes, 1).pane_command = nil
          terminal(panes, 2).pane_command = nil
        end),
      })
      expect.equality(zellij.list(tools.all()), {})
    end)

    it("skips an exited pane, even one that still carries a matching pane_command", function()
      rec = record({
        [LIST_SESSIONS] = "skuA\n",
        [PANES_A] = patched("list_panes_a.json", function(panes)
          local exited = terminal(panes, 3)
          exited.pane_command = "/usr/local/bin/claude"
          expect.equality(exited.exited, true)
          terminal(panes, 1).exited = true
        end),
      })
      expect.equality(zellij.list(tools.all())[1].pane, "terminal_2")
    end)

    it("lists a floating pane that runs a tool", function()
      rec = record({
        [LIST_SESSIONS] = "skuA\n",
        [PANES_A] = patched("list_panes_a.json", function(panes)
          terminal(panes, 1).is_floating = true
        end),
      })
      local list = zellij.list(tools.all())
      expect.equality(list[1].pane, "terminal_1")
    end)

    it("gives no session when no tool is configured", function()
      rec = record(routes())
      expect.equality(zellij.list({}), {})
    end)

    it("lists nothing, without an error, when zellij has no session", function()
      rec = record({ [LIST_SESSIONS] = { code = 1, stdout = "", stderr = "No active zellij sessions found.\n" } })
      local list, err = zellij.list(tools.all())
      expect.equality({ list, err }, { {} })
      expect.equality(#rec.subs, 1)
    end)

    it("skips a session that vanished after list-sessions and keeps the others", function()
      local r = routes()
      r[PANES_A] = NOT_FOUND
      rec = record(r)
      local list, err = zellij.list(tools.all())
      expect.equality(err, nil)
      expect.equality(
        vim.tbl_map(function(s)
          return s.id
        end, list),
        { "zellij:skuB:terminal_5" }
      )
    end)

    it("maps any other failure of a step to backend_error with its exit code", function()
      for step, label in pairs({ [LIST_SESSIONS] = "list-sessions", [PANES_A] = "list-panes" }) do
        local r = routes()
        r[step] = { code = 3, stdout = "", stderr = "something else\n" }
        rec = record(r)
        local list, err = zellij.list(tools.all())
        rec.restore()
        rec = nil
        expect.equality(list, nil)
        expect.equality({ err.id, err.backend, err.cmd, err.code }, { "backend_error", "zellij", label, 3 })
      end
    end)

    it("maps malformed pane lists to backend_error", function()
      for _, bad in ipairs({ "not json", '{"panes":[]}', '[{"id":"x"}]', '["x"]', "" }) do
        local r = routes()
        r[PANES_A] = bad
        rec = record(r)
        local list, err = zellij.list(tools.all())
        rec.restore()
        rec = nil
        expect.equality(list, nil)
        expect.equality({ err.id, err.backend, err.cmd }, { "backend_error", "zellij", "list-panes" })
      end
    end)

    it("reports a matching pane without a working directory", function()
      for _, cwd in ipairs({ vim.NIL, "" }) do
        local r = routes()
        r[PANES_A] = patched("list_panes_a.json", function(panes)
          terminal(panes, 1).pane_cwd = cwd ~= vim.NIL and cwd or nil
        end)
        rec = record(r)
        local list, err = zellij.list(tools.all())
        rec.restore()
        rec = nil
        expect.equality(list, nil)
        expect.equality({ err.id, err.cmd }, { "backend_error", "list-panes" })
      end
    end)

    it("does not need a working directory for a pane that matches no tool", function()
      local r = routes()
      r[PANES_A] = patched("list_panes_a.json", function(panes)
        terminal(panes, 4).pane_cwd = nil
      end)
      rec = record(r)
      local list, err = zellij.list(tools.all())
      expect.equality(err, nil)
      expect.equality(#list, 3)
    end)

    it("skips a vanished session only for exit 1 with \"Session '...' not found\"", function()
      for _, failed in ipairs({
        { code = 2, stdout = "", stderr = "Session 'skuA' not found\n" },
        { code = 1, stdout = "", stderr = "Session 'skuA' exploded\n" },
        { code = 1, stdout = "", stderr = "no skuA not found\n" },
      }) do
        local r = routes()
        r[PANES_A] = failed
        rec = record(r)
        local list, err = zellij.list(tools.all())
        rec.restore()
        rec = nil
        expect.equality(list, nil)
        expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "list-panes", failed.code })
      end
    end)

    it("treats zellij as outside when only ZELLIJ_SESSION_NAME is set", function()
      vim.env.ZELLIJ_SESSION_NAME = "skuB"
      rec = record(routes())
      zellij.list(tools.all())
      expect.equality(rec.keys(), { LIST_SESSIONS, PANES_A, PANES_B })
    end)

    it("reports the no-session text only for a failed list-sessions with empty stdout", function()
      rec = record({
        [LIST_SESSIONS] = { code = 1, stdout = "skuA\n", stderr = "No active zellij sessions found.\n" },
      })
      local list, err = zellij.list(tools.all())
      expect.equality(list, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "list-sessions", 1 })
    end)

    it("fails with backend_error and runs nothing when the binary cannot be found", function()
      vim.env.PATH = "/nonexistent-sku-path"
      rec = record({})
      local list, err = zellij.list(tools.all())
      expect.equality(list, nil)
      expect.equality({ err.id, err.backend }, { "backend_error", "zellij" })
      expect.equality(rec.calls, {})
    end)
  end)

  describe("is_running", function()
    ---@param panes_json string
    ---@param session? table
    ---@return boolean
    local function running(panes_json, session)
      rec = record({ [PANES_A] = panes_json })
      local result = zellij.is_running(session or claude())
      expect.equality(rec.keys(), { PANES_A })
      rec.restore()
      rec = nil
      return result
    end

    it("makes one list-panes call for the session and is true for a present, running pane", function()
      expect.equality(running(fixture("list_panes_a.json")), true)
    end)

    it("is false when the pane has exited", function()
      expect.equality(
        running(patched("list_panes_a.json", function(panes)
          local pane = terminal(panes, 1)
          pane.exited = true
          pane.pane_command = nil
        end)),
        false
      )
    end)

    it("is false when the pane is gone", function()
      expect.equality(
        running(patched("list_panes_a.json", function(panes)
          for i, pane in ipairs(panes) do
            if pane.id == 1 and not pane.is_plugin then
              table.remove(panes, i)
              break
            end
          end
        end)),
        false
      )
    end)

    it("is false when the program changed", function()
      expect.equality(
        running(patched("list_panes_a.json", function(panes)
          terminal(panes, 1).pane_command = "/bin/sh"
        end)),
        false
      )
    end)

    it("asks the tool's is_proc, not equality with proc_name: a stale proc_name still runs", function()
      expect.equality(
        running(
          fixture("list_panes_a.json"),
          claude(function(s)
            s.proc_name = "env"
          end)
        ),
        true
      )
    end)

    it("is false, without a call, for a tool that is no longer configured", function()
      rec = record({})
      expect.equality(
        zellij.is_running(claude(function(s)
          s.tool = "gone-tool"
        end)),
        false
      )
      expect.equality(rec.calls, {})
    end)

    it("ignores everything after argv0 when comparing the program", function()
      expect.equality(
        running(patched("list_panes_a.json", function(panes)
          terminal(panes, 1).pane_command = "/usr/local/bin/claude --other-flag"
        end)),
        true
      )
    end)

    it("is false for a plugin pane that shares the id", function()
      local json = patched("list_panes_a.json", function(panes)
        table.insert(panes, {
          id = 9,
          is_plugin = true,
          exited = false,
          pane_command = "/usr/local/bin/claude",
        })
      end)
      expect.equality(
        running(
          json,
          claude(function(s)
            s.pane = "terminal_9"
          end)
        ),
        false
      )
    end)

    it("is false when the session is gone", function()
      rec = record({ [PANES_A] = NOT_FOUND })
      expect.equality(zellij.is_running(claude()), false)
    end)

    it("stays true when zellij fails or prints something unreadable, so no attached session is dropped", function()
      for _, result in ipairs({
        { code = 2, stdout = "", stderr = "boom\n" },
        { code = 1, stdout = "", stderr = "Session 'skuA' exploded\n" },
        ok("not json"),
        ok('[{"id":"x"}]'),
      }) do
        rec = record({ [PANES_A] = result })
        expect.equality(zellij.is_running(claude()), true)
        rec.restore()
        rec = nil
      end
    end)
  end)

  describe("start", function()
    local function inside()
      vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID, vim.env.ZELLIJ_SESSION_NAME = "0", "0", "skuA"
    end

    local NEW_PANE =
      "--session skuA action new-pane --direction right --no-focus --cwd /tmp/sku-proj-a --name sku-claude --"

    ---@param suffix string the command after `--`
    ---@param panes? string
    local function routes(suffix, panes)
      return {
        [NEW_PANE .. suffix] = fixture("new_pane.txt"),
        [PANES_A] = panes or fixture("list_panes_a_started.json"),
      }
    end

    ---@param env_table? table<string, string>
    ---@return sidekick_ultra.Session? session
    ---@return sidekick_ultra.Error? err
    local function start(env_table)
      return zellij.start(tools.get("claude"), { cwd = "/tmp/sku-proj-a", env = env_table or {} })
    end

    before_each(inside)

    it("splits right of nvim's pane without focus, then maps the new pane with one list-panes call", function()
      rec = record(routes(" /bin/sh"))
      local session, err = start()
      expect.equality(err, nil)
      expect.equality(rec.keys(), { NEW_PANE .. " /bin/sh", PANES_A })
      expect.equality(session, {
        id = "zellij:skuA:terminal_6",
        backend = "zellij",
        tool = "claude",
        cwd = "/tmp/sku-proj-a",
        proc_name = "claude",
        zellij_session = "skuA",
        pane = "terminal_6",
      })
    end)

    it("returns a session that is running at once", function()
      rec = record(routes(" /bin/sh"))
      expect.equality(zellij.is_running((start())), true)
    end)

    it("passes the tool command as separate arguments after --", function()
      tools.setup({ claude = { cmd = { "claude", "--model", "x y" } } })
      rec = record(routes(" claude --model x y"))
      local session = start()
      expect.equality(rec.calls[1].argv, {
        bin,
        "--session",
        "skuA",
        "action",
        "new-pane",
        "--direction",
        "right",
        "--no-focus",
        "--cwd",
        "/tmp/sku-proj-a",
        "--name",
        "sku-claude",
        "--",
        "claude",
        "--model",
        "x y",
      })
      expect.equality(session.pane, "terminal_6")
    end)

    it("puts a non-empty tool env in front of the command as /usr/bin/env K=V, sorted", function()
      rec = record(routes(" /usr/bin/env A=1 B=two /bin/sh"))
      local session = start({ B = "two", A = "1" })
      expect.equality(session.pane, "terminal_6")
      expect.equality(vim.list_slice(rec.calls[1].argv, 13), { "--", "/usr/bin/env", "A=1", "B=two", "/bin/sh" })
    end)

    it("records the tool's command name, not env, while the pane still runs the env wrapper", function()
      local wrapper = patched("list_panes_a_started.json", function(panes)
        terminal(panes, 6).pane_command = "/usr/bin/env A=1 /bin/sh"
      end)
      rec = record(routes(" /usr/bin/env A=1 /bin/sh", wrapper))
      local session, err = start({ A = "1" })
      expect.equality(err, nil)
      expect.equality({ session.pane, session.proc_name }, { "terminal_6", "sh" })
      rec.restore()

      -- env then execs the tool: the same session counts as running. A program that is not the tool does not.
      rec = record({ [PANES_A] = fixture("list_panes_a_started.json") })
      expect.equality(zellij.is_running(session), true)
      rec.restore()
      rec = record({
        [PANES_A] = patched("list_panes_a_started.json", function(panes)
          terminal(panes, 6).pane_command = "/bin/sleep 300"
        end),
      })
      expect.equality(zellij.is_running(session), false)
    end)

    it("fails without a session name and runs nothing", function()
      vim.env.ZELLIJ_SESSION_NAME = ""
      rec = record({})
      local session, err = start()
      expect.equality(session, nil)
      expect.equality({ err.id, err.backend, err.cmd }, { "backend_error", "zellij", "new-pane" })
      expect.equality(rec.calls, {})
    end)

    it("maps a failing new-pane to backend_error and maps nothing", function()
      rec = record({ [NEW_PANE .. " /bin/sh"] = { code = 1, stdout = "", stderr = "no room\n" } })
      local session, err = start()
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "new-pane", 1 })
      expect.equality(#rec.subs, 1)
    end)

    it("fails when new-pane prints no terminal id", function()
      for _, out in ipairs({ "", "plugin_3\n", "terminal_x\n", "terminal_6 extra\n" }) do
        rec = record({ [NEW_PANE .. " /bin/sh"] = out })
        local session, err = start()
        rec.restore()
        rec = nil
        expect.equality(session, nil)
        expect.equality({ err.id, err.cmd }, { "backend_error", "new-pane" })
        -- The text must say why zellij prints nothing, and that a pane may still be open.
        for _, part in ipairs({ "no room", "floating", "sku-claude", "left open", "skuA" }) do
          expect.equality({ part, err.msg:find(part, 1, true) ~= nil }, { part, true })
        end
      end
    end)

    it("fails, naming the pane left open, when the new pane is not in the listing or not running", function()
      for _, panes in ipairs({
        fixture("list_panes_a.json"),
        patched("list_panes_a_started.json", function(list)
          terminal(list, 6).exited = true
        end),
        patched("list_panes_a_started.json", function(list)
          terminal(list, 6).pane_command = nil
        end),
      }) do
        rec = record(routes(" /bin/sh", panes))
        local session, err = start()
        rec.restore()
        rec = nil
        expect.equality(session, nil)
        expect.equality({ err.id, err.cmd }, { "backend_error", "new-pane" })
        expect.equality(err.msg:find("terminal_6", 1, true) ~= nil and err.msg:find("left open", 1, true) ~= nil, true)
      end
    end)

    it("reports a failing list-panes after new-pane", function()
      rec = record(routes(" /bin/sh", ""))
      local session, err = start()
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "list-panes" })
    end)

    it("is picked by registry.start, which focuses the new pane afterwards", function()
      registry.register(zellij)
      local focus = "--session skuA action focus-pane-id terminal_6"
      rec = record({
        ["--session skuA action new-pane --direction right --no-focus --cwd " .. vim.fn.getcwd() .. " --name sku-claude -- /bin/sh"] = fixture(
          "new_pane.txt"
        ),
        [PANES_A] = fixture("list_panes_a_started.json"),
        [focus] = "",
      })
      local session = registry.start(tools.get("claude"))
      expect.equality(session.id, "zellij:skuA:terminal_6")
      expect.equality(#rec.subs, 3)
      expect.equality(rec.keys()[3], focus)
    end)
  end)

  describe("send", function()
    local WRITE = write_chars("skuA", "terminal_1", "hello world")

    ---@param keys string[]
    ---@return boolean
    local function wrote(keys)
      return #vim.tbl_filter(function(key)
        return key:find("write-chars", 1, true) ~= nil
      end, keys) > 0
    end

    it("checks the pane, then writes the raw text after -- with no Enter", function()
      rec = record({ [PANES_A] = fixture("list_panes_a.json"), [WRITE] = "" })
      expect.equality({ zellij.send(claude(), "hello world") }, { true })
      expect.equality(rec.keys(), { PANES_A, WRITE })
      expect.equality(rec.calls[2].argv, {
        bin,
        "--session",
        "skuA",
        "action",
        "write-chars",
        "--pane-id",
        "terminal_1",
        "--",
        "hello world",
      })
    end)

    it("keeps a leading dash and a newline in the text as one argument", function()
      local text = "-a\ncd"
      rec = record({
        [PANES_A] = fixture("list_panes_a.json"),
        [write_chars("skuA", "terminal_1", text)] = "",
      })
      expect.equality({ zellij.send(claude(), text) }, { true })
      expect.equality(rec.calls[2].argv[8], "--")
      expect.equality(rec.calls[2].argv[9], text)
    end)

    it("sends nothing and runs nothing for empty text", function()
      rec = record({})
      expect.equality({ zellij.send(claude(), "") }, { true })
      expect.equality(rec.calls, {})
    end)

    it("refuses a gone pane with backend_error naming the pane and session, and never calls write-chars", function()
      rec = record({
        [PANES_A] = patched("list_panes_a.json", function(panes)
          for i, pane in ipairs(panes) do
            if pane.id == 1 and not pane.is_plugin then
              table.remove(panes, i)
              break
            end
          end
        end),
        [WRITE] = "",
      })
      local ok_, err = zellij.send(claude(), "hello world")
      expect.equality(ok_, nil)
      expect.equality({ err.id, err.backend, err.cmd }, { "backend_error", "zellij", "write-chars" })
      expect.equality(err.msg:find("terminal_1", 1, true) ~= nil and err.msg:find("skuA", 1, true) ~= nil, true)
      expect.equality(wrote(rec.keys()), false)
    end)

    it("refuses an exited pane, and a pane whose program changed, without writing", function()
      for _, patch in ipairs({
        function(panes)
          local pane = terminal(panes, 1)
          pane.exited = true
          pane.pane_command = nil
        end,
        function(panes)
          terminal(panes, 1).pane_command = "/bin/sh"
        end,
      }) do
        rec = record({ [PANES_A] = patched("list_panes_a.json", patch), [WRITE] = "" })
        local ok_, err = zellij.send(claude(), "hello world")
        expect.equality(wrote(rec.keys()), false)
        rec.restore()
        rec = nil
        expect.equality(ok_, nil)
        expect.equality({ err.id, err.cmd }, { "backend_error", "write-chars" })
      end
    end)

    it("refuses when the session is gone, without writing", function()
      rec = record({ [PANES_A] = NOT_FOUND, [WRITE] = "" })
      local ok_, err = zellij.send(claude(), "hello world")
      expect.equality(ok_, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "write-chars" })
      expect.equality(wrote(rec.keys()), false)
    end)

    it("returns the error of a failing pane check and does not write", function()
      rec = record({ [PANES_A] = { code = 2, stdout = "", stderr = "boom\n" }, [WRITE] = "" })
      local ok_, err = zellij.send(claude(), "hello world")
      expect.equality(ok_, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "list-panes", 2 })
      expect.equality(wrote(rec.keys()), false)
    end)

    it("maps a failing write-chars to backend_error with its exit code", function()
      rec = record({
        [PANES_A] = fixture("list_panes_a.json"),
        [WRITE] = { code = 1, stdout = "", stderr = "denied\n" },
      })
      local ok_, err = zellij.send(claude(), "hello world")
      expect.equality(ok_, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "write-chars", 1 })
    end)
  end)

  describe("submit and focus", function()
    it("submit presses Enter in the pane", function()
      local key = "--session skuA action send-keys --pane-id terminal_1 Enter"
      rec = record({ [key] = "" })
      expect.equality({ zellij.submit(claude()) }, { true })
      expect.equality(rec.keys(), { key })
    end)

    it("focus focuses the pane by id", function()
      local key = "--session skuA action focus-pane-id terminal_1"
      rec = record({ [key] = "" })
      expect.equality({ zellij.focus(claude()) }, { true })
      expect.equality(rec.keys(), { key })
    end)

    it("map a non-zero exit to backend_error with the exit code", function()
      for method, label in pairs({ submit = "send-keys", focus = "focus-pane-id" }) do
        rec = record({
          ["--session skuA action send-keys --pane-id terminal_1 Enter"] = { code = 1, stdout = "", stderr = "nope\n" },
          ["--session skuA action focus-pane-id terminal_1"] = { code = 1, stdout = "", stderr = "nope\n" },
        })
        local ok_, err = zellij[method](claude())
        rec.restore()
        rec = nil
        expect.equality(ok_, nil)
        expect.equality({ err.id, err.backend, err.cmd, err.code }, { "backend_error", "zellij", label, 1 })
      end
    end)
  end)

  describe("through the registry", function()
    it("decides liveness with its own is_running and never reads a pid", function()
      registry.register(zellij)
      rec = record({ [PANES_A] = fixture("list_panes_a.json") })
      expect.equality(registry.is_running(claude()), true)
      rec.restore()
      rec = record({
        [PANES_A] = patched("list_panes_a.json", function(panes)
          terminal(panes, 1).pane_command = "/bin/sh"
        end),
      })
      expect.equality(registry.is_running(claude()), false)
    end)

    it("discovers zellij sessions and attaches them", function()
      registry.register(zellij)
      rec = record({ [LIST_SESSIONS] = "skuA\n", [PANES_A] = fixture("list_panes_a.json") })
      local list = registry.discover()
      expect.equality(
        vim.tbl_map(function(s)
          return s.id
        end, list),
        { "zellij:skuA:terminal_1", "zellij:skuA:terminal_2" }
      )
      expect.equality(list[1].sid, registry.sid("claude", "/tmp/sku-proj-a"))
      local calls = #rec.subs
      expect.equality(registry.attach(list[1]), true)
      -- The attach event is scheduled; its status refresh asks the backend, which must go through the seam. Let it
      -- run now, while the seam is still replaced, and leave nothing scheduled behind.
      vim.wait(100, function()
        return #rec.subs > calls
      end)
      expect.equality(rec.keys()[calls + 1], PANES_A)
      expect.equality(#require("sidekick-ultra.status").cli(), 1)
      registry.detach_all()
      vim.wait(50)
    end)
  end)

  -- Supervisor condition: pane_command beyond argv0 may carry secrets. Every input below has SECRET in the
  -- pane_command of every terminal pane (an exited pane included), so a leak from any path can show. Nothing the
  -- backend returns, raises or notifies may contain it.
  describe("pane_command arguments", function()
    local cap
    local NEW_PANE_SH =
      "--session skuA action new-pane --direction right --no-focus --cwd /tmp/sku-proj-a --name sku-claude -- /bin/sh"
    local NEW_PANE_ENV =
      "--session skuA action new-pane --direction right --no-focus --cwd /tmp/sku-proj-a --name sku-claude -- /usr/bin/env TOKEN=SECRET-TOKEN-xyz /bin/sh"

    before_each(function()
      cap = notify.capture()
    end)

    after_each(function()
      cap.restore()
    end)

    ---A pane list whose every terminal pane, the exited one too, carries SECRET after its program.
    ---@param name string
    ---@param patch? fun(panes: table[])
    ---@return string
    local function leaky(name, patch)
      local json = patched(name, function(panes)
        for _, pane in ipairs(panes) do
          if not pane.is_plugin then
            pane.pane_command = (pane.pane_command or "/bin/sh") .. " --token " .. SECRET
          end
        end
        if patch then
          patch(panes)
        end
      end)
      expect.equality(json:find(SECRET, 1, true) ~= nil, true)
      return json
    end

    ---@param value any
    local function expect_clean(value)
      expect.equality(vim.inspect(value):find(SECRET, 1, true), nil)
    end

    ---An error value, and the toast it would become, carry no SECRET.
    ---@param err sidekick_ultra.Error
    local function expect_clean_error(err)
      expect.equality(type(err), "table")
      expect_clean(err)
      local before = #cap.calls
      errors.notify(err)
      expect.equality(#cap.calls, before + 1)
      expect_clean(cap.calls)
    end

    ---@param panes_list string
    ---@param other? table additional routes
    ---@return table
    local function start_routes(panes_list, other)
      return vim.tbl_extend("force", { [NEW_PANE_SH] = fixture("new_pane.txt"), [PANES_A] = panes_list }, other or {})
    end

    local function start_inside()
      vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID, vim.env.ZELLIJ_SESSION_NAME = "0", "0", "skuA"
      return zellij.start(tools.get("claude"), { cwd = "/tmp/sku-proj-a", env = {} })
    end

    it("reach no session and no call of list", function()
      rec = record({
        [LIST_SESSIONS] = fixture("list_sessions.txt"),
        [PANES_A] = leaky("list_panes_a.json"),
        [PANES_B] = leaky("list_panes_b.json"),
      })
      local list = zellij.list(tools.all())
      expect.equality(#list, 3)
      expect_clean(list)
      expect_clean(rec.subs)
    end)

    it("reach no session of list inside zellij", function()
      vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID, vim.env.ZELLIJ_SESSION_NAME = "0", "0", "skuA"
      rec = record({ [PANES_A] = leaky("list_panes_a.json") })
      local list = zellij.list(tools.all())
      expect.equality(#list, 2)
      expect_clean(list)
    end)

    it("reach no session of registry.discover", function()
      registry.register(zellij)
      rec = record({ [LIST_SESSIONS] = "skuA\n", [PANES_A] = leaky("list_panes_a.json") })
      local list = registry.discover()
      expect.equality(#list, 2)
      expect_clean(list)
    end)

    it("reach no error of list", function()
      local inputs = {
        leaky("list_panes_a.json", function(panes)
          terminal(panes, 1).pane_cwd = nil
        end),
        leaky("list_panes_a.json", function(panes)
          terminal(panes, 1).pane_cwd = ""
        end),
        '[{"id":"x","pane_command":"/bin/sh --token ' .. SECRET .. '"}]',
        "not json " .. SECRET,
        { code = 3, stdout = "out " .. SECRET, stderr = "boom\n" },
      }
      for _, input in ipairs(inputs) do
        rec = record({ [LIST_SESSIONS] = "skuA\n", [PANES_A] = input })
        local list, err = zellij.list(tools.all())
        rec.restore()
        rec = nil
        expect.equality(list, nil)
        expect_clean_error(err)
      end
    end)

    it("reach no result of is_running, which never notifies", function()
      for _, case in ipairs({
        { leaky("list_panes_a.json"), true },
        {
          leaky("list_panes_a.json", function(panes)
            terminal(panes, 1).pane_command = "/bin/sh --token " .. SECRET
          end),
          false,
        },
        { { code = 2, stdout = "out " .. SECRET, stderr = "boom\n" }, true },
      }) do
        rec = record({ [PANES_A] = case[1] })
        local result = zellij.is_running(claude())
        expect.equality(#rec.subs, 1)
        rec.restore()
        rec = nil
        expect.equality(result, case[2])
      end
      expect.equality(cap.calls, {})
    end)

    it("reach no refusal or error of send", function()
      for _, input in ipairs({
        leaky("list_panes_a.json", function(panes)
          terminal(panes, 1).pane_command = "/bin/sh --token " .. SECRET
        end),
        leaky("list_panes_a.json", function(panes)
          terminal(panes, 1).exited = true
        end),
        leaky("list_panes_a.json", function(panes)
          for i, pane in ipairs(panes) do
            if pane.id == 1 and not pane.is_plugin then
              table.remove(panes, i)
              break
            end
          end
        end),
        { code = 1, stdout = "out " .. SECRET, stderr = "Session 'skuA' not found\n" },
        { code = 2, stdout = "out " .. SECRET, stderr = "boom\n" },
        '[{"id":"x","pane_command":"/bin/sh --token ' .. SECRET .. '"}]',
      }) do
        rec = record({ [PANES_A] = input, [write_chars("skuA", "terminal_1", "text")] = "" })
        local ok_, err = zellij.send(claude(), "text")
        local wrote_text = vim.tbl_contains(rec.keys(), write_chars("skuA", "terminal_1", "text"))
        rec.restore()
        rec = nil
        expect.equality(ok_, nil)
        expect.equality(wrote_text, false)
        expect_clean_error(err)
      end
    end)

    it("reach no session of start, even when the new pane still shows the env wrapper with a secret", function()
      for _, case in ipairs({
        { NEW_PANE_SH, "claude", function() end },
        {
          NEW_PANE_ENV,
          "sh",
          function(panes)
            terminal(panes, 6).pane_command = "/usr/bin/env TOKEN=" .. SECRET .. " /bin/sh"
          end,
        },
      }) do
        rec = record({
          [case[1]] = fixture("new_pane.txt"),
          [PANES_A] = leaky("list_panes_a_started.json", case[3]),
        })
        local env_table = case[1] == NEW_PANE_ENV and { TOKEN = SECRET } or {}
        vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID, vim.env.ZELLIJ_SESSION_NAME = "0", "0", "skuA"
        local session, err = zellij.start(tools.get("claude"), { cwd = "/tmp/sku-proj-a", env = env_table })
        rec.restore()
        rec = nil
        expect.equality(err, nil)
        expect.equality(session.proc_name, case[2])
        expect_clean(session)
      end
    end)

    it("reach no error of start", function()
      local cases = {
        -- new-pane printed something else, which may echo anything
        { { [NEW_PANE_SH] = "oops " .. SECRET .. "\n" } },
        -- the new pane is not in the listing, has exited, or lost its command
        { start_routes(leaky("list_panes_a.json")) },
        {
          start_routes(leaky("list_panes_a_started.json", function(panes)
            terminal(panes, 6).exited = true
          end)),
        },
        {
          start_routes(leaky("list_panes_a_started.json", function(panes)
            terminal(panes, 6).pane_command = nil
          end)),
        },
        -- the pane has no working directory
        {
          start_routes(leaky("list_panes_a_started.json", function(panes)
            terminal(panes, 6).pane_cwd = nil
          end)),
        },
        -- the mapping call fails or prints something unreadable
        { start_routes({ code = 2, stdout = "out " .. SECRET, stderr = "boom\n" }) },
        { start_routes('[{"id":"x","pane_command":"/bin/sh --token ' .. SECRET .. '"}]') },
        { start_routes("not json " .. SECRET) },
      }
      for _, case in ipairs(cases) do
        local routes_table = case[1]
        if routes_table[NEW_PANE_SH] and not routes_table[PANES_A] then
          routes_table[PANES_A] = ""
        end
        rec = record(routes_table)
        local session, err = start_inside()
        rec.restore()
        rec = nil
        expect.equality(session, nil)
        expect_clean_error(err)
      end
    end)
  end)
end)
