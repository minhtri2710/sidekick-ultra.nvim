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
  local rec, dir, bin, orig_now, orig_wait, waits
  -- The fake clock `start` reads (milliseconds): it moves only through zellij.wait, and a route may move it too.
  local clock
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
    -- `start` reads zellij.now and waits through zellij.wait; the specs drive a fake clock and take no wait.
    orig_now, orig_wait, waits, clock = zellij.now, zellij.wait, {}, 0
    zellij.now = function()
      return clock
    end
    zellij.wait = function(ms)
      table.insert(waits, ms)
      clock = clock + ms
    end
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
    zellij.now, zellij.wait = orig_now, orig_wait
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

    it(
      "reports empty output of a successful list-sessions or list-panes as no answer, never as no sessions or panes",
      function()
        for _, case in ipairs({
          { LIST_SESSIONS, "", "list-sessions" },
          { LIST_SESSIONS, "\n  \n", "list-sessions" },
          { PANES_A, "", "list-panes" },
          { PANES_A, " \n", "list-panes" },
        }) do
          local r = routes()
          r[case[1]] = case[2]
          rec = record(r)
          local list, err = zellij.list(tools.all())
          rec.restore()
          rec = nil
          expect.equality(list, nil)
          expect.equality({ err.id, err.cmd }, { "backend_error", case[3] })
          expect.equality(err.msg:find("did not answer", 1, true) ~= nil, true)
        end
      end
    )

    it("takes the text [] as an answer: a session without terminal panes", function()
      local r = routes()
      r[PANES_A] = "[]"
      rec = record(r)
      local list, err = zellij.list(tools.all())
      expect.equality(err, nil)
      expect.equality(#list, 1)
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

    it("stays true when list-panes exits 0 and prints nothing", function()
      for _, empty in ipairs({ "", "\n" }) do
        rec = record({ [PANES_A] = empty })
        expect.equality(zellij.is_running(claude()), true)
        rec.restore()
        rec = nil
      end
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

    ---A started-pane listing whose pane 6 runs `command`.
    ---@param command? string
    local function with_command(command)
      return patched("list_panes_a_started.json", function(panes)
        terminal(panes, 6).pane_command = command
      end)
    end

    ---A list-panes route for the wait: `answers` in order (the last repeats), each call recorded in `polls` with the
    ---clock at its start, and each taking `cost` ms of the fake clock.
    local polls
    local function timed(answers, cost)
      polls = {}
      return function(n)
        table.insert(polls, clock)
        clock = clock + (cost or 0)
        return answers[math.min(n, #answers)]
      end
    end

    local function bound_error_names_everything(err)
      expect.equality({ err.id, err.cmd }, { "backend_error", "new-pane" })
      for _, part in ipairs({ "claude", "terminal_6", "skuA", "left open", "never showed" }) do
        expect.equality({ part, err.msg:find(part, 1, true) ~= nil }, { part, true })
      end
      -- Not even the program's basename is echoed.
      expect.equality(err.msg:find("node", 1, true), nil)
    end

    it("waits with the event loop running, on a monotonic clock, when nothing is faked", function()
      local ran = false
      vim.schedule(function()
        ran = true
      end)
      local t0 = orig_now()
      orig_wait(30)
      expect.equality(ran, true)
      expect.equality(orig_now() - t0 >= 25, true)
    end)

    it("returns on the first poll, without waiting, when the pane already shows the tool", function()
      local r = routes(" /bin/sh")
      r[PANES_A] = timed({ fixture("list_panes_a_started.json") })
      rec = record(r)
      expect.equality(start().proc_name, "claude")
      expect.equality(polls, { 0 })
      expect.equality(waits, {})
    end)

    it("waits through an env answer and a shell answer until the pane shows the tool, before the deadline", function()
      local started = fixture("list_panes_a_started.json")
      local r = routes(" /usr/bin/env A=1 /bin/sh")
      r[PANES_A] = timed({ with_command("/usr/bin/env A=1 /bin/sh"), with_command("/bin/bash"), started })
      rec = record(r)
      local session, err = start({ A = "1" })
      expect.equality(err, nil)
      expect.equality({ session.pane, session.proc_name }, { "terminal_6", "claude" })
      expect.equality(polls, { 0, 50, 100 })
      expect.equality(waits, { 50, 50 })
      rec.restore()
      -- The session it returns is running by the plain rule.
      rec = record({ [PANES_A] = started })
      expect.equality(zellij.is_running(session), true)
    end)

    it(
      "ends at the deadline with the pane named when the program never shows as the tool, and polls no later",
      function()
        local r = routes(" /bin/sh")
        r[PANES_A] = timed({ with_command("node script.js") })
        rec = record(r)
        local session, err = start()
        expect.equality(session, nil)
        bound_error_names_everything(err)
        expect.equality(clock, 2000)
        expect.equality(polls[1], 0)
        expect.equality(polls[#polls] < 2000, true)
        expect.equality(polls[#polls] >= 2000 - 50, true)
        expect.equality(
          vim.tbl_filter(function(ms)
            return ms ~= 50
          end, waits),
          {}
        )
      end
    )

    it("starts no poll after the deadline when the answers themselves are slow", function()
      local r = routes(" /bin/sh")
      r[PANES_A] = timed({ with_command("node script.js") }, 900)
      rec = record(r)
      local session, err = start()
      expect.equality(session, nil)
      bound_error_names_everything(err)
      expect.equality(polls, { 0, 950, 1900 })
      expect.equality(clock, 2800)
    end)

    it("fails at once, naming the pane, when the pane exits or vanishes during the wait", function()
      local wrapper = with_command("/usr/bin/env A=1 /bin/sh")
      local exited = patched("list_panes_a_started.json", function(panes)
        terminal(panes, 6).exited = true
      end)
      for _, second in ipairs({ exited, fixture("list_panes_a.json") }) do
        local r = routes(" /usr/bin/env A=1 /bin/sh")
        r[PANES_A] = timed({ wrapper, second })
        rec = record(r)
        local session, err = start({ A = "1" })
        rec.restore()
        rec = nil
        expect.equality(session, nil)
        expect.equality({ err.id, err.cmd }, { "backend_error", "new-pane" })
        expect.equality(err.msg:find("terminal_6", 1, true) ~= nil and err.msg:find("left open", 1, true) ~= nil, true)
        expect.equality(polls, { 0, 50 })
        waits, clock = {}, 0
      end
    end)

    it("asks again after an empty answer in the wait", function()
      local r = routes(" /bin/sh")
      r[PANES_A] = timed({ "\n", with_command("/bin/bash"), "", fixture("list_panes_a_started.json") })
      rec = record(r)
      local session, err = start()
      expect.equality(err, nil)
      expect.equality(session.proc_name, "claude")
      expect.equality(polls, { 0, 50, 100, 150 })
    end)

    it("ends empty answers at the deadline with the no-answer error, each taking its second", function()
      local r = routes(" /bin/sh")
      r[PANES_A] = timed({ "\n" }, 1000)
      rec = record(r)
      local session, err = start()
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "list-panes" })
      expect.equality(err.msg:find("did not answer", 1, true) ~= nil, true)
      -- The second poll started at 1050, before the deadline; the third would start at 2100, after it.
      expect.equality(polls, { 0, 1050 })
      expect.equality(clock, 2050)
    end)

    it("stops at once when list-panes fails in the wait", function()
      local r = routes(" /bin/sh")
      r[PANES_A] = function(n)
        return n == 1 and with_command("/bin/bash") or { code = 2, stdout = "", stderr = "boom\n" }
      end
      rec = record(r)
      local session, err = start()
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "list-panes", 2 })
      expect.equality(waits, { 50 })
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

    it("reports a failing list-panes after new-pane at once", function()
      rec = record(routes(" /bin/sh", { code = 2, stdout = "", stderr = "boom\n" }))
      local session, err = start()
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "list-panes", 2 })
      expect.equality(waits, {})
    end)

    it("is picked by registry.start, which only creates the pane", function()
      registry.register(zellij)
      rec = record({
        ["--session skuA action new-pane --direction right --no-focus --cwd " .. vim.fn.getcwd() .. " --name sku-claude -- /bin/sh"] = fixture(
          "new_pane.txt"
        ),
        [PANES_A] = fixture("list_panes_a_started.json"),
      })
      local session = registry.start(tools.get("claude"))
      expect.equality(session.id, "zellij:skuA:terminal_6")
      expect.equality(#rec.subs, 2)
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

    it(
      "does not read an empty answer of the pane check as a gone pane: it reports no answer and writes nothing",
      function()
        rec = record({ [PANES_A] = "", [WRITE] = "" })
        local ok_, err = zellij.send(claude(), "hello world")
        expect.equality(ok_, nil)
        expect.equality({ err.id, err.cmd }, { "backend_error", "list-panes" })
        expect.equality(err.msg:find("did not answer", 1, true) ~= nil, true)
        expect.equality(wrote(rec.keys()), false)
      end
    )

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
      local calls = #rec.subs
      expect.equality(registry.attach(list[1]), true)
      -- The liveness check asks the backend, which must go through the seam.
      registry.check()
      expect.equality(rec.keys()[calls + 1], PANES_A)
      expect.equality(#registry.attached(), 1)
      -- Let the attach event run while the seam is still replaced, and leave nothing scheduled behind.
      registry.detach_all()
      vim.wait(50)
    end)
  end)

  -- A tool installed as a node or python script runs as its interpreter, so the program of a pane is the script's name
  -- (see procname). Everything else about `pane_command` stays as before: only argv0 or the script word is read.
  describe("script names", function()
    local cap
    local NEW_PANE_G =
      "--session skuA action new-pane --direction right --no-focus --cwd /tmp/sku-proj-a --name sku-gemini -- /bin/sh"

    before_each(function()
      cap = notify.capture()
      fake.reset({
        claude = { cmd = fake.INSTALLED },
        gemini = { cmd = fake.INSTALLED },
        aider = { cmd = fake.INSTALLED },
        qwen = { cmd = fake.INSTALLED },
      }, { zellij = { enabled = false } })
    end)

    after_each(function()
      cap.restore()
    end)

    ---The pane list of session skuA with terminal pane 1 running `command`.
    ---@param command? string
    ---@return string
    local function pane_1(command)
      return patched("list_panes_a.json", function(panes)
        terminal(panes, 1).pane_command = command
      end)
    end

    ---The tool found in pane terminal_1 of skuA for `command`, and the program recorded for it.
    ---@param command string
    ---@return string? tool
    ---@return string? proc_name
    local function discovered(command)
      rec = record({ [LIST_SESSIONS] = "skuA\n", [PANES_A] = pane_1(command) })
      local list, err = zellij.list(tools.all())
      expect.equality(err, nil)
      rec.restore()
      rec = nil
      local found = vim.tbl_filter(function(s)
        return s.pane == "terminal_1"
      end, list)
      return found[1] and found[1].tool, found[1] and found[1].proc_name
    end

    ---@param tool string
    ---@param proc_name string
    local function session_of(tool, proc_name)
      return claude(function(s)
        s.tool, s.proc_name = tool, proc_name
      end)
    end

    it("finds a node tool by its script name and records that name as the program", function()
      expect.equality({ discovered("/opt/homebrew/bin/node /x/bin/gemini --flag value") }, { "gemini", "gemini" })
    end)

    it("takes every interpreter name and the script word after its flags", function()
      for _, case in ipairs({
        { "node /x/bin/gemini", "gemini" },
        { "nodejs /x/bin/gemini", "gemini" },
        { "/usr/bin/bun /x/bin/gemini", "gemini" },
        { "node -- /x/bin/gemini", "gemini" },
        { "node --require ./hook.js --inspect=9229 /x/bin/gemini", "gemini" },
        { "python /x/bin/aider", "aider" },
        { "python3 -m aider --model x", "aider" },
        { "python3.12 -u /x/bin/aider.py", "aider" },
        { "/usr/bin/Python -W ignore -m aider", "aider" },
      }) do
        expect.equality({ case[1], (discovered(case[1])) }, { case[1], case[2] })
      end
    end)

    it("finds no tool for an interpreter that runs no script, or a script that is not a tool", function()
      for _, command in ipairs({
        "node -e gemini",
        "node --eval gemini",
        "node -p gemini",
        "node --print gemini",
        "node",
        "python3 -c aider",
        "python3",
        "node /x/dist/index.js",
        "python3 -m pip install gemini",
        "node /x/bin/other gemini",
        "node /x/bin/other --name=gemini",
        "nodemon /x/bin/gemini",
        "Python3 /x/bin/aider",
      }) do
        expect.equality({ command, (discovered(command)) }, { command, nil })
      end
    end)

    it("leaves a program that is not an interpreter as the basename of its first word", function()
      expect.equality({ discovered("/usr/local/bin/claude --resume x") }, { "claude", "claude" })
    end)

    it("is_running follows the script: true while it is the tool, false when it changes or runs code", function()
      for _, case in ipairs({
        { "node /x/bin/gemini --api-key x", true },
        { "bun -r ./hook.js /x/bin/gemini", true },
        { "node /x/bin/other", false },
        { "node -e gemini", false },
        { "node", false },
      }) do
        rec = record({ [PANES_A] = pane_1(case[1]) })
        expect.equality({ case[1], zellij.is_running(session_of("gemini", "gemini")) }, { case[1], case[2] })
        rec.restore()
        rec = nil
      end
      rec = record({ [PANES_A] = pane_1("python3 -m aider") })
      expect.equality(zellij.is_running(session_of("aider", "aider")), true)
    end)

    it("send writes to a pane running the script, and refuses one that runs other code", function()
      local WRITE = write_chars("skuA", "terminal_1", "hello")
      rec = record({ [PANES_A] = pane_1("node /x/bin/gemini --x"), [WRITE] = "" })
      expect.equality({ zellij.send(session_of("gemini", "gemini"), "hello") }, { true })
      expect.equality(rec.keys(), { PANES_A, WRITE })
      rec.restore()
      rec = record({ [PANES_A] = pane_1("node -e hello"), [WRITE] = "" })
      local ok_, err = zellij.send(session_of("gemini", "gemini"), "hello")
      expect.equality({ ok_, err.id, err.cmd }, { nil, "backend_error", "write-chars" })
      expect.equality(rec.keys(), { PANES_A })
    end)

    describe("start", function()
      before_each(function()
        vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID, vim.env.ZELLIJ_SESSION_NAME = "0", "0", "skuA"
      end)

      ---@param command string
      ---@return string
      local function pane_6(command)
        return patched("list_panes_a_started.json", function(panes)
          terminal(panes, 6).pane_command = command
        end)
      end

      local function start()
        return zellij.start(tools.get("gemini"), { cwd = "/tmp/sku-proj-a", env = {} })
      end

      it("returns once the pane's interpreter runs the tool's script, recording the script's name", function()
        local wrapper, running = pane_6("/bin/bash"), pane_6("node /x/bin/gemini --flag")
        rec = record({
          [NEW_PANE_G] = fixture("new_pane.txt"),
          [PANES_A] = function(n)
            return n <= 1 and wrapper or running
          end,
        })
        local session, err = start()
        expect.equality(err, nil)
        expect.equality(session.proc_name, "gemini")
        expect.equality(waits, { 50 })
        rec.restore()
        rec = record({ [PANES_A] = running })
        expect.equality(zellij.is_running(session), true)
      end)

      it("keeps waiting while the interpreter runs another script, and ends at the bound without naming it", function()
        rec = record({ [NEW_PANE_G] = fixture("new_pane.txt"), [PANES_A] = pane_6("node /x/bin/other") })
        local session, err = start()
        expect.equality(session, nil)
        expect.equality({ err.id, err.cmd }, { "backend_error", "new-pane" })
        expect.equality(err.msg:find("never showed as gemini", 1, true) ~= nil, true)
        expect.equality(err.msg:find("node", 1, true), nil)
        expect.equality(err.msg:find("other", 1, true), nil)
        expect.equality(#waits > 0, true)
      end)

      it("keeps waiting while the pane's interpreter runs code and no script, then returns at the script", function()
        local answers = { pane_6("node -e setup()"), pane_6("python3 -c x"), pane_6("node /x/bin/gemini") }
        rec = record({
          [NEW_PANE_G] = fixture("new_pane.txt"),
          [PANES_A] = function(n)
            return answers[math.min(n, #answers)]
          end,
        })
        local session, err = start()
        expect.equality(err, nil)
        expect.equality({ session.proc_name, waits }, { "gemini", { 50, 50 } })
      end)

      it("fails at once when the pane's command is gone", function()
        rec = record({ [NEW_PANE_G] = fixture("new_pane.txt"), [PANES_A] = pane_6(nil) })
        local session, err = start()
        expect.equality({ session, err.id }, { nil, "backend_error" })
        expect.equality(waits, {})
      end)
    end)

    -- Supervisor condition: the command line beyond the script word may carry a secret. Every command line below
    -- holds SECRET; nothing the backend returns, raises or notifies may hold it.
    describe("command line arguments", function()
      local LINES = {
        { "node /x/bin/gemini --api-key " .. SECRET, "gemini" },
        { "node --require " .. SECRET .. " /x/bin/gemini", "gemini" },
        { 'node -e "' .. SECRET .. '"', nil },
        { "python3 -m aider --token " .. SECRET, "aider" },
        { 'python3 -c "' .. SECRET .. '"', nil },
        { 'node -pe "/x/' .. SECRET .. '/gemini"', nil },
        { 'node -ep "/x/' .. SECRET .. '/gemini"', nil },
        { "node --eval=0 /x/" .. SECRET .. "/gemini", nil },
        { "node --print=0 /x/" .. SECRET .. "/gemini", nil },
        { "node --run /x/" .. SECRET .. "/gemini", nil },
        { "node --env-file " .. SECRET .. " /x/bin/gemini", "gemini" },
        { "node --title " .. SECRET .. " /x/bin/gemini", "gemini" },
        { "node --config-file /x/bin/qwen --x /x/" .. SECRET .. "/gemini", "qwen" },
        { "node - /x/" .. SECRET .. "/gemini", nil },
        { 'python3 -uc "/x/' .. SECRET .. '/gemini"', nil },
        { "python3 -c/x/" .. SECRET .. "/gemini", nil },
        { "python3 -Wc /x/bin/aider --token " .. SECRET, nil },
        { "python3 -maider /x/" .. SECRET .. "/gemini", nil },
        { "python3 -uX /x/" .. SECRET .. "/gemini /x/bin/aider", "aider" },
        { "python3 --check-hash-based-pycs " .. SECRET .. " /x/bin/aider", "aider" },
        { "python3 - /x/" .. SECRET .. "/gemini", nil },
      }

      ---@param value any
      local function expect_clean(value)
        expect.equality(vim.inspect(value):find(SECRET, 1, true), nil)
      end

      it("reach no session or recorded call of list or registry.discover", function()
        registry.register(zellij)
        for _, case in ipairs(LINES) do
          rec = record({ [LIST_SESSIONS] = "skuA\n", [PANES_A] = pane_1(case[1]) })
          local list = zellij.list(tools.all())
          local found = vim.tbl_filter(function(session)
            return session.pane == "terminal_1"
          end, list)
          expect.equality(found[1] and found[1].tool, case[2])
          expect_clean({ list, rec.subs })
          local discovered_list = registry.discover()
          expect_clean(discovered_list)
          rec.restore()
          rec = nil
        end
        expect.equality(cap.calls, {})
      end)

      it("reach no result of is_running", function()
        for _, case in ipairs(LINES) do
          for _, tool in ipairs({ { "gemini", "gemini" }, { "aider", "aider" } }) do
            rec = record({ [PANES_A] = pane_1(case[1]) })
            local running = zellij.is_running(session_of(tool[1], tool[2]))
            expect.equality(running, case[2] == tool[1])
            expect_clean({ running, rec.subs })
            rec.restore()
            rec = nil
          end
        end
        expect.equality(cap.calls, {})
      end)

      it("reach no refusal of send, and no write for a pane that runs code", function()
        for _, case in ipairs(LINES) do
          local tool = case[2] or "gemini"
          local write = write_chars("skuA", "terminal_1", "text")
          rec = record({ [PANES_A] = pane_1(case[1]), [write] = "" })
          local ok_, err = zellij.send(session_of(tool, tool), "text")
          expect.equality(ok_ == true, case[2] ~= nil)
          if err then
            local before = #cap.calls
            errors.notify(err)
            expect.equality(#cap.calls, before + 1)
          end
          expect_clean({ ok_, err, rec.subs, cap.calls })
          expect.equality(vim.tbl_contains(rec.keys(), write), case[2] ~= nil)
          rec.restore()
          rec = nil
        end
      end)

      it("reach no session or error of start, in the wait or at its bound", function()
        vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID, vim.env.ZELLIJ_SESSION_NAME = "0", "0", "skuA"
        local function pane_6(command)
          return patched("list_panes_a_started.json", function(panes)
            terminal(panes, 6).pane_command = command
          end)
        end
        for _, case in ipairs(LINES) do
          local tool = case[2] or "gemini"
          local wrapper, running = pane_6("/bin/bash"), pane_6(case[1])
          rec = record({
            [NEW_PANE_G:gsub("sku%-gemini", "sku-" .. tool)] = fixture("new_pane.txt"),
            [PANES_A] = function(n)
              return n <= 1 and wrapper or running
            end,
          })
          local session, err = zellij.start(tools.get(tool), { cwd = "/tmp/sku-proj-a", env = {} })
          rec.restore()
          rec = nil
          waits = {}
          expect.equality(session ~= nil, case[2] ~= nil)
          if err then
            expect.equality(err.msg:find("never showed", 1, true) ~= nil, true)
            errors.notify(err)
          end
          expect_clean({ session, err, cap.calls })
        end
      end)
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

    it(
      "reach no session of start, even when the new pane shows the env wrapper with a secret before the tool",
      function()
        for _, case in ipairs({
          { NEW_PANE_SH, {}, 0 },
          { NEW_PANE_ENV, { TOKEN = SECRET }, 2 },
        }) do
          local wrapper = leaky("list_panes_a_started.json", function(panes)
            terminal(panes, 6).pane_command = "/usr/bin/env TOKEN=" .. SECRET .. " /bin/sh"
          end)
          local started = leaky("list_panes_a_started.json")
          rec = record({
            [case[1]] = fixture("new_pane.txt"),
            [PANES_A] = function(n)
              return n <= case[3] and wrapper or started
            end,
          })
          vim.env.ZELLIJ, vim.env.ZELLIJ_PANE_ID, vim.env.ZELLIJ_SESSION_NAME = "0", "0", "skuA"
          local session, err = zellij.start(tools.get("claude"), { cwd = "/tmp/sku-proj-a", env = case[2] })
          rec.restore()
          rec = nil
          expect.equality(err, nil)
          expect.equality(session.proc_name, "claude")
          expect.equality(#waits, case[3])
          expect_clean(session)
          waits = {}
        end
      end
    )

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
        -- the program never shows as the tool (env wrapper or interpreter carrying the secret), or no answer at all
        {
          start_routes(leaky("list_panes_a_started.json", function(panes)
            terminal(panes, 6).pane_command = "/usr/bin/env TOKEN=" .. SECRET .. " /bin/sh"
          end)),
        },
        {
          start_routes(leaky("list_panes_a_started.json", function(panes)
            terminal(panes, 6).pane_command = "node script.js --token " .. SECRET
          end)),
        },
        { start_routes("\n") },
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
