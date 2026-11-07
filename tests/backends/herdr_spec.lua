local fake = require("tests.helpers.fake")
local helper = require("tests.helpers.backend")
local herdr = require("sidekick-ultra.backends.herdr")

local expect = MiniTest.expect

local fixture = helper.fixtures("herdr", ".json")
local SELF_PID, SELF_NAME = fake.self_proc()
-- A pid no process has, so `nvim_get_proc` finds nothing.
local GONE_PID = 2000000000

---Decode a fixture, let `patch` change it, and encode it again.
---@param name string
---@param patch fun(data: table)
---@return string
local function patched(name, patch)
  local data = vim.json.decode(fixture(name), { luanil = { object = true, array = true } })
  patch(data)
  return vim.json.encode(data)
end

---A process-info fixture whose pids are replaced through `pids` (fixture pid -> real pid).
---@param name string
---@param pids table<integer, integer>
---@return string
local function process_info(name, pids)
  return patched(name, function(data)
    local info = data.result.process_info
    for _, process in ipairs(info.foreground_processes) do
      process.pid = pids[process.pid] or process.pid
    end
    info.shell_pid = pids[info.shell_pid] or info.shell_pid
    if info.foreground_process_group_id then
      info.foreground_process_group_id = pids[info.foreground_process_group_id] or info.foreground_process_group_id
    end
  end)
end

local CLAUDE_PROCESS = process_info("process_info_claude", { [4241] = GONE_PID, [4242] = SELF_PID })
-- Only the shell is a process here, so a session built from the foreground entries would be dropped.
local SHELL_PROCESS = process_info("process_info_claude", { [4200] = SELF_PID, [4241] = GONE_PID, [4242] = GONE_PID })
local CODEX_PROCESS = process_info("process_info_codex", { [4251] = SELF_PID, [4252] = GONE_PID })

---A failed command whose stderr carries the given error-envelope fixture.
local function failing(name)
  return { code = 1, stdout = "", stderr = fixture(name):gsub("\n", "") .. "\n" }
end

local FORBIDDEN = { "--session", "--remote", "--machine" }

describe("herdr backend", function()
  local rec
  local orig_pane, orig_path

  ---Replace `exec.run`. `routes` maps `"<subcommand> <subcommand>"` (argv[2] argv[3]) to its answer (see the
  ---recorder in tests/helpers/backend.lua). An unrouted command fails the case.
  ---@param routes table<string, string|table|fun(n: integer, argv: string[]): string|table>
  local function install(routes)
    if rec then
      rec.restore()
    end
    rec = helper.record(routes, function(argv)
      return argv[2] .. " " .. argv[3]
    end)
  end

  ---The argv of every recorded call.
  local function argvs()
    return rec.argvs()
  end

  ---The word after `flag` in `argv`.
  ---@param argv string[]
  ---@param flag string
  ---@return string?
  local function after(argv, flag)
    return argv[vim.fn.index(argv, flag) + 2]
  end

  local function tools()
    fake.reset({ claude = {}, codex = {} })
    return require("sidekick-ultra.tools").all()
  end

  ---@return sidekick_ultra.Session
  local function pane_session()
    return vim.tbl_extend("force", fake.session("herdr", "claude", 1), {
      id = "herdr:w1:p1",
      pane_id = "w1:p1",
    })
  end

  before_each(function()
    orig_pane = vim.env.HERDR_PANE_ID
    orig_path = vim.env.PATH
    vim.env.HERDR_PANE_ID = nil
  end)
  after_each(function()
    vim.env.HERDR_PANE_ID = orig_pane
    vim.env.PATH = orig_path
    if rec then
      local calls = rec.calls
      rec.restore()
      rec = nil
      -- herdr runs only its own binary, as a backend call, and never aims at another herdr.
      for _, call in ipairs(calls) do
        expect.equality({ call.argv[1], call.opts.backend }, { "herdr", "herdr" })
        for _, token in ipairs(FORBIDDEN) do
          expect.equality(vim.tbl_contains(call.argv, token), false)
        end
      end
    end
  end)

  describe("contract", function()
    it("resolves the binary from PATH", function()
      local ok, path, source = herdr.available()
      expect.equality(ok, true)
      expect.equality(vim.endswith(path, "/tests/bin/herdr"), true)
      expect.equality(source, "PATH")
    end)

    it("is unavailable when PATH has no herdr", function()
      vim.env.PATH = "/usr/bin:/bin"
      expect.equality({ herdr.available() }, { false })
    end)

    it("is inside when HERDR_PANE_ID is non-empty", function()
      expect.equality(herdr.inside(), false)
      vim.env.HERDR_PANE_ID = ""
      expect.equality(herdr.inside(), false)
      vim.env.HERDR_PANE_ID = "w1:p1"
      expect.equality(herdr.inside(), true)
    end)
  end)

  describe("list", function()
    local function routes(extra)
      return vim.tbl_extend("force", {
        ["pane list"] = fixture("pane_list"),
        ["pane process-info"] = function(_, argv)
          return argv[5] == "w1:p2" and CODEX_PROCESS or CLAUDE_PROCESS
        end,
      }, extra or {})
    end

    it("lists the panes of every workspace and asks process-info only for matching panes", function()
      install(routes())
      herdr.list(tools())
      expect.equality(argvs(), {
        { "herdr", "pane", "list" },
        { "herdr", "pane", "process-info", "--pane", "w1:p1" },
        { "herdr", "pane", "process-info", "--pane", "w1:p2" },
        { "herdr", "pane", "process-info", "--pane", "w2:p2" },
      })
    end)

    it("maps agent panes to configured tools and reads pid, cwd and state", function()
      install(routes())
      local sessions, err = herdr.list(tools())
      expect.equality(err, nil)
      expect.equality(sessions, {
        {
          id = "herdr:w1:p1",
          backend = "herdr",
          tool = "claude",
          cwd = "/work/proj",
          pid = SELF_PID,
          proc_name = SELF_NAME,
          state = "idle",
          pane_id = "w1:p1",
        },
        {
          id = "herdr:w1:p2",
          backend = "herdr",
          tool = "codex",
          cwd = "/work/other",
          pid = SELF_PID,
          proc_name = SELF_NAME,
          state = "working",
          pane_id = "w1:p2",
        },
        {
          id = "herdr:w2:p2",
          backend = "herdr",
          tool = "claude",
          cwd = "/work/two",
          pid = SELF_PID,
          proc_name = SELF_NAME,
          state = "blocked",
          pane_id = "w2:p2",
        },
      })
    end)

    it("falls back to the first entry when the group id matches none", function()
      install(routes({
        ["pane process-info"] = patched("process_info_claude", function(data)
          local info = data.result.process_info
          info.foreground_process_group_id = 1
          info.foreground_processes[1].pid = SELF_PID
          info.foreground_processes[2].pid = GONE_PID
        end),
      }))
      expect.equality(#herdr.list(tools()), 3)
    end)

    it("never keeps argv, cmdline or any other process field", function()
      install(routes())
      expect.equality(vim.inspect(herdr.list(tools())):find("ARGV_MARKER", 1, true), nil)
    end)

    it("skips a pane whose foreground pid is not a process here", function()
      install(routes({
        ["pane process-info"] = process_info("process_info_claude", { [4241] = GONE_PID, [4242] = GONE_PID }),
      }))
      expect.equality(herdr.list(tools()), {})
    end)

    it("skips a pane with no foreground process", function()
      install(routes({
        ["pane process-info"] = patched("process_info_claude", function(data)
          data.result.process_info.foreground_processes = {}
        end),
      }))
      expect.equality(herdr.list(tools()), {})
    end)

    it("skips a pane without a cwd and falls back from foreground_cwd to cwd", function()
      install(routes({
        ["pane list"] = patched("pane_list", function(data)
          local panes = data.result.panes
          panes[1].foreground_cwd, panes[1].cwd = nil, nil
          panes[2].foreground_cwd, panes[2].cwd = nil, "/work/only-cwd"
        end),
      }))
      local sessions = herdr.list(tools())
      expect.equality(
        vim.tbl_map(function(s)
          return { s.id, s.cwd }
        end, sessions),
        { { "herdr:w1:p2", "/work/only-cwd" }, { "herdr:w2:p2", "/work/two" } }
      )
    end)

    it("maps an unrecognized agent_status to unknown", function()
      install(routes({
        ["pane list"] = patched("pane_list", function(data)
          data.result.panes[1].agent_status = "bogus"
        end),
      }))
      expect.equality(herdr.list(tools())[1].state, "unknown")
    end)

    it("returns an empty list for a herdr with no panes", function()
      install(routes({ ["pane list"] = fixture("pane_list_empty") }))
      expect.equality(herdr.list(tools()), {})
    end)

    it("lists no panes, and no error, when no herdr server is running", function()
      install(routes({ ["pane list"] = failing("server_not_running") }))
      expect.equality({ herdr.list(tools()) }, { {} })
      expect.equality(argvs(), { { "herdr", "pane", "list" } })
    end)

    it("still reports every other pane list failure with its text", function()
      for stderr, text in pairs({
        [failing("server_unavailable").stderr] = "herdr exited with 1: "
          .. fixture("server_unavailable"):gsub("\n", ""),
        ["not json\n"] = "herdr exited with 1: not json",
        ["\n"] = "herdr exited with 1",
      }) do
        install(routes({ ["pane list"] = { code = 1, stdout = "", stderr = stderr } }))
        local sessions, err = herdr.list(tools())
        expect.equality(sessions, nil)
        expect.equality(
          { err.id, err.backend, err.cmd, err.code, err.msg },
          { "backend_error", "herdr", "pane list", 1, text }
        )
      end
    end)

    it("reports a failing process-info as backend_error", function()
      install(routes({ ["pane process-info"] = failing("error") }))
      local sessions, err = herdr.list(tools())
      expect.equality(sessions, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "pane process-info" })
    end)

    it("reports a malformed response as backend_error", function()
      for _, body in ipairs({
        "not json",
        "",
        "[]",
        '{"id":"x","result":{"type":"pane_list"}}',
        '{"id":"x","result":{"type":"pane_list","panes":"nope"}}',
        '{"id":"x","result":{"type":"pane_list","panes":[{"agent":"claude"}]}}',
      }) do
        install(routes({ ["pane list"] = body }))
        local sessions, err = herdr.list(tools())
        expect.equality(sessions, nil)
        expect.equality({ err.id, err.backend, err.cmd }, { "backend_error", "herdr", "pane list" })
      end
      install(routes({ ["pane process-info"] = '{"id":"x","result":{"type":"pane_process_info"}}' }))
      local _, err = herdr.list(tools())
      expect.equality({ err.id, err.cmd }, { "backend_error", "pane process-info" })
    end)
  end)

  describe("start", function()
    local function routes(extra)
      return vim.tbl_extend("force", {
        ["agent list"] = fixture("agent_list"),
        ["pane split"] = fixture("pane_split"),
        ["agent start"] = fixture("agent_started"),
        ["pane process-info"] = SHELL_PROCESS,
        ["pane close"] = fixture("ok"),
      }, extra or {})
    end

    ---@param name? string
    ---@param cmd? string[]
    local function tool(name, cmd)
      name = name or "claude"
      return { name = name, cmd = cmd or { name }, env = {} }
    end

    before_each(function()
      vim.env.HERDR_PANE_ID = "w1:p1"
    end)

    it("splits beside nvim's own pane by id without focus, then starts the agent in the new pane", function()
      install(routes())
      local session, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality(err, nil)
      expect.equality(argvs(), {
        { "herdr", "agent", "list" },
        { "herdr", "pane", "split", "--pane", "w1:p1", "--direction", "right", "--cwd", "/work/proj", "--no-focus" },
        {
          "herdr",
          "agent",
          "start",
          "sku-claude-3",
          "--kind",
          "claude",
          "--pane",
          "w1:p4",
          "--timeout",
          "30000",
        },
        { "herdr", "pane", "process-info", "--pane", "w1:p4" },
      })
      expect.equality(session, {
        id = "herdr:w1:p4",
        backend = "herdr",
        tool = "claude",
        cwd = "/work/proj-real",
        pid = SELF_PID,
        proc_name = SELF_NAME,
        state = "idle",
        pane_id = "w1:p4",
      })
    end)

    it("passes one --env per entry, sorted, before --no-focus", function()
      install(routes())
      herdr.start(tool(), { cwd = "/work/proj", env = { ZED = "last one", ALPHA = "a=b" } })
      expect.equality(argvs()[2], {
        "herdr",
        "pane",
        "split",
        "--pane",
        "w1:p1",
        "--direction",
        "right",
        "--cwd",
        "/work/proj",
        "--env",
        "ALPHA=a=b",
        "--env",
        "ZED=last one",
        "--no-focus",
      })
    end)

    it("passes tool.cmd[2..] after -- and nothing else of the command", function()
      install(routes())
      herdr.start(tool("copilot", { "copilot", "--banner", "two words" }), { cwd = "/work/proj", env = {} })
      expect.equality(argvs()[3], {
        "herdr",
        "agent",
        "start",
        "sku-copilot-1",
        "--kind",
        "copilot",
        "--pane",
        "w1:p4",
        "--timeout",
        "30000",
        "--",
        "--banner",
        "two words",
      })
    end)

    it("waits longer for agent start than the exec default", function()
      install(routes())
      herdr.start(tool(), { cwd = "/work/proj", env = {} })
      local start_call = rec.calls[3]
      expect.equality(start_call.opts.timeout_ms > tonumber(after(start_call.argv, "--timeout")), true)
    end)

    it("uses the requested cwd when herdr reports none", function()
      install(routes({ ["agent start"] = fixture("agent_started_no_cwd") }))
      local session = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality(session.cwd, "/work/proj")
    end)

    it("refuses a tool that is not a herdr agent kind before running anything", function()
      install(routes())
      local session, err = herdr.start(tool("aider"), { cwd = "/work/proj", env = {} })
      expect.equality(session, nil)
      expect.equality({ err.id, err.backend, err.cmd }, { "backend_error", "herdr", "agent start" })
      expect.equality(#rec.calls, 0)
    end)

    it("refuses a command that is not the executable herdr launches for the kind", function()
      install(routes())
      local _, err = herdr.start(tool("claude", { "/usr/local/bin/claude" }), { cwd = "/work/proj", env = {} })
      expect.equality(err.id, "backend_error")
      expect.equality(#rec.calls, 0)
      _, err = herdr.start(tool("cursor", { "cursor" }), { cwd = "/work/proj", env = {} })
      expect.equality(err.id, "backend_error")
      install(routes())
      local session = herdr.start(tool("cursor", { "cursor-agent" }), { cwd = "/work/proj", env = {} })
      expect.equality(session ~= nil, true)
      expect.equality(after(argvs()[3], "--kind"), "cursor")
    end)

    it("creates nothing when agent list fails", function()
      install(routes({ ["agent list"] = failing("error") }))
      local session, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "agent list" })
      expect.equality(#rec.calls, 1)
    end)

    it("starts no agent and closes nothing when the split fails", function()
      install(routes({ ["pane split"] = failing("error") }))
      local session, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "pane split" })
      expect.equality(#rec.calls, 2)
    end)

    it("rejects a split response without a pane id", function()
      install(routes({ ["pane split"] = '{"id":"x","result":{"type":"pane_info","pane":{}}}' }))
      local _, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality({ err.id, err.cmd }, { "backend_error", "pane split" })
      expect.equality(#rec.calls, 2)
    end)

    it("keeps an agent that is blocked during startup: no pane close, a session with state blocked", function()
      install(routes({ ["agent start"] = failing("agent_start_not_ready") }))
      local session, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality(err, nil)
      expect.equality(session, {
        id = "herdr:w1:p4",
        backend = "herdr",
        tool = "claude",
        cwd = "/work/proj",
        pid = SELF_PID,
        proc_name = SELF_NAME,
        state = "blocked",
        pane_id = "w1:p4",
      })
      expect.equality(argvs()[4], { "herdr", "pane", "process-info", "--pane", "w1:p4" })
      expect.equality(#rec.calls, 4)
    end)

    it("returns backend_error without closing the pane when a blocked agent's shell is not visible here", function()
      install(routes({
        ["agent start"] = failing("agent_start_not_ready"),
        ["pane process-info"] = process_info("process_info_claude", { [4200] = GONE_PID }),
      }))
      local session, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality(session, nil)
      expect.equality(err.id, "backend_error")
      expect.equality(#rec.calls, 4)
      expect.equality(argvs()[4][3], "process-info")
    end)

    it("closes exactly the pane it just split for every agent start failure, and returns the start error", function()
      for _, row in ipairs({
        { failing("agent_start_timeout"), 1 },
        { failing("error"), 1 },
        { { code = 2, stdout = "", stderr = "missing required --kind\n" }, 2 },
        { { code = 1, stdout = "", stderr = "" }, 1 },
        { { code = 0, stdout = "not json", stderr = "" }, 0 },
        { { code = 0, stdout = '{"id":"x","result":{"type":"agent_started"}}', stderr = "" } },
        { { run_error = { id = "backend_error", msg = "timed out", backend = "herdr", cmd = "agent start" } } },
      }) do
        install(routes({ ["agent start"] = row[1] }))
        local session, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
        expect.equality(session, nil)
        expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "agent start", row[2] })
        expect.equality(argvs()[4], { "herdr", "pane", "close", "w1:p4" })
        expect.equality(#rec.calls, 4)
      end
    end)

    it("words invalid JSON from agent start as it does for every other herdr query", function()
      install(routes({ ["agent start"] = "not json" }))
      local _, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality(err.msg, "herdr printed invalid JSON")
    end)

    it("still returns the start error when the cleanup close fails too", function()
      install(routes({ ["agent start"] = failing("error"), ["pane close"] = failing("error") }))
      local _, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality({ err.id, err.cmd }, { "backend_error", "agent start" })
      expect.equality(#rec.calls, 4)
    end)

    it("returns backend_error when the shell pid is not a process here, and leaves the pane", function()
      install(routes({ ["pane process-info"] = process_info("process_info_claude", { [4200] = GONE_PID }) }))
      local session, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "agent start" })
      expect.equality(
        vim.tbl_contains(
          vim.tbl_map(function(argv)
            return argv[3]
          end, argvs()),
          "close"
        ),
        false
      )
    end)

    it("returns backend_error when process-info has no shell pid", function()
      install(routes({
        ["pane process-info"] = patched("process_info_claude", function(data)
          data.result.process_info.shell_pid = nil
        end),
      }))
      local session, err = herdr.start(tool(), { cwd = "/work/proj", env = {} })
      expect.equality(session, nil)
      expect.equality(err.id, "backend_error")
    end)
  end)

  describe("send", function()
    local function routes(extra)
      return vim.tbl_extend("force", {
        ["pane get"] = fixture("pane_get_idle"),
        ["pane send-text"] = fixture("ok"),
      }, extra or {})
    end

    it("re-reads the state, then sends the text as one literal argv element", function()
      install(routes())
      local text = "  fix @a.lua :L3\n--flag 'quoted' $HOME\n"
      expect.equality({ herdr.send(pane_session(), text) }, { true })
      expect.equality(argvs(), {
        { "herdr", "pane", "get", "w1:p1" },
        { "herdr", "pane", "send-text", "w1:p1", text },
      })
    end)

    it("sends for every readable state except blocked", function()
      for _, state in ipairs({ "idle", "working", "done", "unknown" }) do
        install(routes({
          ["pane get"] = patched("pane_get_idle", function(data)
            data.result.pane.agent_status = state
          end),
        }))
        expect.equality({ herdr.send(pane_session(), "x") }, { true })
        expect.equality(#rec.calls, 2)
      end
    end)

    it("refuses a blocked pane with session_blocked and sends nothing", function()
      install(routes({ ["pane get"] = fixture("pane_get_blocked") }))
      local ok, err = herdr.send(pane_session(), "hello")
      expect.equality(ok, nil)
      expect.equality(err.id, "session_blocked")
      expect.equality(argvs(), { { "herdr", "pane", "get", "w1:p1" } })
    end)

    it("refuses with status_unreadable when the read fails, and sends nothing", function()
      install(routes({ ["pane get"] = failing("error") }))
      local ok, err = herdr.send(pane_session(), "hello")
      expect.equality(ok, nil)
      expect.equality({ err.id, err.backend, err.cmd, err.code }, { "status_unreadable", "herdr", "pane get", 1 })
      expect.equality(#rec.calls, 1)
    end)

    it("refuses with status_unreadable when the read is ambiguous, and sends nothing", function()
      for _, body in ipairs({
        "not json",
        "",
        fixture("pane_get_unrecognized"),
        '{"id":"x","result":{"type":"pane_info"}}',
        '{"id":"x","result":{"type":"pane_info","pane":{"pane_id":"w1:p1"}}}',
        '{"id":"x","result":{"type":"pane_info","pane":{"agent_status":null}}}',
      }) do
        install(routes({ ["pane get"] = body }))
        local ok, err = herdr.send(pane_session(), "hello")
        expect.equality(ok, nil)
        expect.equality(err.id, "status_unreadable")
        expect.equality(#rec.calls, 1)
      end
    end)

    it("reports a failing send-text as backend_error", function()
      install(routes({ ["pane send-text"] = failing("error") }))
      local ok, err = herdr.send(pane_session(), "hello")
      expect.equality(ok, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "pane send-text", 1 })
    end)
  end)

  describe("submit and focus", function()
    it("submit sends the Enter key to the pane", function()
      install({ ["pane send-keys"] = fixture("ok") })
      expect.equality({ herdr.submit(pane_session()) }, { true })
      expect.equality(argvs(), { { "herdr", "pane", "send-keys", "w1:p1", "Enter" } })
    end)

    it("submit reports a failure as backend_error", function()
      install({ ["pane send-keys"] = failing("error") })
      local ok, err = herdr.submit(pane_session())
      expect.equality(ok, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "pane send-keys" })
    end)

    it("focus uses agent focus on the pane id, never pane focus", function()
      install({ ["agent focus"] = fixture("ok") })
      expect.equality({ herdr.focus(pane_session()) }, { true })
      expect.equality(argvs(), { { "herdr", "agent", "focus", "w1:p1" } })
    end)

    it("focus reports a failure as backend_error", function()
      install({ ["agent focus"] = failing("error") })
      local ok, err = herdr.focus(pane_session())
      expect.equality(ok, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "agent focus" })
    end)
  end)
end)
