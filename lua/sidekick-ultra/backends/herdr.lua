---The herdr backend: sessions are herdr panes whose detected agent kind is a configured tool. nvim talks to the
---server it runs under (`HERDR_SOCKET_PATH` is inherited); no command passes `--session`, `--remote` or `--machine`.
---Only pids, names, ids, cwds, states and a foreground process's argv0 are read from herdr's answers; argv beyond argv0,
---cmdline and environment never are.
local contract = require("sidekick-ultra.backend")
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")
local proc = require("sidekick-ultra.proc")

local M = { name = "herdr" }

---The `agent_status` values herdr reports. They are the source of `sidekick_ultra.AgentState` (backend.lua), which
---changes with this list.
---@type table<string, true>
local STATES = { idle = true, working = true, blocked = true, done = true, unknown = true }

---Agent kinds `herdr agent start` accepts, each with the executable herdr launches for it (the label is the
---executable unless listed in EXECUTABLE). herdr reports a pane's kind as the same label, so a tool is startable
---and discoverable exactly when its name is one of these.
local KINDS = {
  "pi",
  "claude",
  "codex",
  "gemini",
  "cursor",
  "devin",
  "agy",
  "cline",
  "omp",
  "mastracode",
  "opencode",
  "copilot",
  "kimi",
  "kiro",
  "droid",
  "amp",
  "grok",
  "hermes",
  "kilo",
  "qodercli",
  "qwen",
  "letta",
  "maki",
  "muse",
}
local EXECUTABLE = { cursor = "cursor-agent", kiro = "kiro-cli" }

---`herdr agent start` waits until the agent is interactive, for at most this long (the server accepts 3 s to 300 s).
---herdr returns at readiness (about 3.8 s for a ready tool), so a short value such as 3001 would time out every start.
local START_TIMEOUT_MS = 30000

---The `error.code` of the error envelope `{id, error = {code, message}}` that a failed herdr command prints on
---stderr and exits 1 (`print_response`, src/cli.rs:745-749). nil when `err` has no stderr line or it is no envelope.
---@param err sidekick_ultra.ExecError
---@return string? code
local function envelope_code(err)
  local ok, decoded = exec.decode(err.stderr or "")
  local code = ok and type(decoded) == "table" and type(decoded.error) == "table" and decoded.error.code
  return type(code) == "string" and code or nil
end

---Run `argv`, decode herdr's `{id, result = {type, ...}}` envelope and return `result[field]`, a table.
---@param argv string[] `herdr <group> <subcommand> ...`: the group and subcommand are named in an error
---@param field string
---@param timeout_ms? integer
---@return table? payload
---@return sidekick_ultra.Error? err
local function query(argv, field, timeout_ms)
  local decoded, err = exec.json(argv, { timeout_ms = timeout_ms })
  if err then
    return nil, err
  end
  local payload = type(decoded) == "table" and type(decoded.result) == "table" and decoded.result[field]
  if type(payload) ~= "table" then
    return nil, errors.new("backend_error", ("herdr %s %s: response has no result.%s"):format(argv[2], argv[3], field))
  end
  return payload
end

---The foreground process of a pane: the entry whose pid is the foreground process group, else the first entry.
---@param info table a `PaneProcessInfo`
---@return table? process
local function foreground(info)
  local processes = type(info.foreground_processes) == "table" and info.foreground_processes or {}
  local chosen = processes[1]
  for _, process in ipairs(processes) do
    if type(process) == "table" and process.pid == info.foreground_process_group_id then
      chosen = process
      break
    end
  end
  return type(chosen) == "table" and chosen or nil
end

---@param info table a `PaneProcessInfo`
---@return integer? pid
local function foreground_pid(info)
  local process = foreground(info)
  return process and process.pid
end

---A pane's process chosen by `pick`, with the name this machine's process table gives that pid: the value the
---contract's liveness rule compares against later. Returns nothing when `pick` finds no pid or the pid is not visible
---here.
---@param pane_id string
---@param pick fun(info: table): integer?
---@return integer? pid
---@return string? proc_name
---@return sidekick_ultra.Error? err
local function recorded_process(pane_id, pick)
  local info, err = query({ "herdr", "pane", "process-info", "--pane", pane_id }, "process_info")
  if not info then
    return nil, nil, err
  end
  local pid = pick(info)
  if type(pid) ~= "number" then
    return nil
  end
  local name = proc.name(pid)
  if not name then
    return nil
  end
  return pid, name
end

---Build a session from a `PaneInfo` or `AgentInfo`. A pane without a cwd is an error; returns nothing (no session, no
---error) when the picked process is not running on this machine.
---@param pane_id string
---@param info table
---@param tool sidekick_ultra.Tool
---@param pick fun(info: table): integer? the foreground pid for discovery, the shell pid for a pane just started
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
local function session_of(pane_id, info, tool, pick)
  local cwd = info.foreground_cwd or info.cwd
  if type(cwd) ~= "string" or cwd == "" then
    return nil, errors.new("backend_error", ("herdr printed no working directory for pane %s"):format(pane_id))
  end
  local pid, proc_name, err = recorded_process(pane_id, pick)
  if not pid then
    return nil, err
  end
  return {
    id = M.name .. ":" .. pane_id,
    backend = M.name,
    tool = tool.name,
    cwd = cwd,
    pid = pid,
    proc_name = proc_name,
    state = STATES[info.agent_status] and info.agent_status or "unknown",
    pane_id = pane_id,
  }
end

---@return boolean available
---@return string? path
---@return string? source
function M.available()
  return exec.on_path("herdr")
end

---@return boolean
function M.inside()
  local pane = vim.env.HERDR_PANE_ID
  return pane ~= nil and pane ~= ""
end

---@param tools table<string, sidekick_ultra.Tool>
---@return sidekick_ultra.Session[]? sessions
---@return sidekick_ultra.Error? err
function M.list(tools)
  -- Without --workspace herdr lists the panes of every workspace. With no herdr server running (`server_not_running`,
  -- src/cli/server_not_running.rs) there are no panes.
  local panes, err = query({ "herdr", "pane", "list" }, "panes")
  if not panes then
    if envelope_code(err) == "server_not_running" then
      return {}
    end
    return nil, err
  end
  local sessions = {}
  for _, pane in ipairs(panes) do
    if type(pane) ~= "table" or type(pane.pane_id) ~= "string" then
      return nil, errors.new("backend_error", "herdr pane list: a pane has no pane_id")
    end
    local tool = type(pane.agent) == "string" and tools[pane.agent] or nil
    if tool then
      -- ponytail: one process-info call per matching pane; batch only if herdr grows a combined listing.
      local session, serr = session_of(pane.pane_id, pane, tool, foreground_pid)
      if serr then
        return nil, serr
      end
      table.insert(sessions, session)
    end
  end
  return sessions
end

---@param tool_name string
---@return string? name
---@return sidekick_ultra.Error? err
local function agent_name(tool_name)
  local agents, err = query({ "herdr", "agent", "list" }, "agents")
  if not agents then
    return nil, err
  end
  local taken = {}
  for _, agent in ipairs(agents) do
    if type(agent) == "table" and type(agent.name) == "string" then
      taken[agent.name] = true
    end
  end
  local n = 1
  while taken[("sku-%s-%d"):format(tool_name, n)] do
    n = n + 1
  end
  return ("sku-%s-%d"):format(tool_name, n)
end

---Run `herdr agent start`. It prints an error envelope on stderr and exits 1 when the agent does not become ready.
---`agent_not_ready` (src/cli/agent.rs:608-611) means the agent started but is blocked during startup, for example on a
---trust prompt: it is running, so it counts as started with state blocked. Any other failure is a `backend_error`.
---@param argv string[]
---@return table? agent the started agent's `AgentInfo`, or `{agent_status = "blocked"}` for `agent_not_ready`
---@return sidekick_ultra.Error? err
local function start_agent(argv)
  local agent, err = query(argv, "agent", START_TIMEOUT_MS + exec.DEFAULT_TIMEOUT_MS)
  if not agent and envelope_code(err) == "agent_not_ready" then
    return { agent_status = "blocked" }
  end
  return agent, err
end

---Whether `tool` is the program in front of the pane. The recorded pid cannot say: for a pane `start` made it is the
---shell, which outlives the tool, and text sent to the shell is run by it. So the answer is read fresh: the foreground
---process must be visible to nvim, must not be the pane's shell, and must run `tool` (argv0 first, as on rex: a Claude
---Code `name` is its version).
---@param pane_id string
---@param tool sidekick_ultra.Tool
---@return boolean? in_front
---@return string? front what is in front, when `in_front` is false
---@return sidekick_ultra.Error? err the read or the tool's `is_proc` failed
local function tool_in_front(pane_id, tool)
  local info, err = query({ "herdr", "pane", "process-info", "--pane", pane_id }, "process_info")
  if not info then
    return nil, nil, err
  end
  local process = foreground(info)
  if not process then
    return false, "no foreground process"
  end
  local front = ("pid %s, argv0 %s, name %s"):format(
    tostring(process.pid),
    tostring(process.argv0),
    tostring(process.name)
  )
  if type(process.pid) ~= "number" or not proc.name(process.pid) then
    return false, front .. " (not visible to nvim)"
  end
  if process.pid == info.shell_pid then
    return false, front .. " (the pane's shell)"
  end
  local words = {}
  for _, word in ipairs({ type(process.argv0) == "string" and vim.fs.basename(process.argv0), process.name }) do
    if type(word) == "string" then
      table.insert(words, word)
    end
  end
  local matched, tool_err = proc.tool_of({ [tool.name] = tool }, process.pid, words)
  if tool_err then
    return nil, nil, tool_err
  end
  return matched ~= nil, front
end

---Close the pane of a start that failed after the split and return `err`, which says when the close failed too.
---@param pane_id string
---@param err sidekick_ultra.Error
---@return nil
---@return sidekick_ultra.Error err
local function close_failed(pane_id, err)
  local closed, close_err = exec.check({ "herdr", "pane", "close", pane_id })
  if not closed then
    err.msg = ("%s (closing the new pane %s also failed: %s)"):format(err.msg, pane_id, close_err.msg)
  end
  return nil, err
end

---@param tool sidekick_ultra.Tool
---@param opts sidekick_ultra.StartOpts
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
function M.start(tool, opts)
  local executable = vim.tbl_contains(KINDS, tool.name) and (EXECUTABLE[tool.name] or tool.name) or nil
  if not executable then
    return nil, errors.new("backend_error", ("herdr has no agent kind named %s"):format(tool.name))
  end
  -- herdr launches its own executable for the kind and gets only the arguments, so another command would be ignored.
  if tool.cmd[1] ~= executable then
    return nil,
      errors.new(
        "backend_error",
        ("herdr starts `%s` for %s, but the tool command is `%s`"):format(executable, tool.name, tool.cmd[1])
      )
  end
  local name, err = agent_name(tool.name)
  if not name then
    return nil, err
  end

  local split = { "herdr", "pane", "split", "--pane", vim.env.HERDR_PANE_ID, "--direction", "right", "--cwd", opts.cwd }
  for _, pair in ipairs(exec.env_pairs(opts.env)) do
    vim.list_extend(split, { "--env", pair })
  end
  table.insert(split, "--no-focus")
  local created, split_err = query(split, "pane")
  if not created then
    return nil, split_err
  end
  local new_id = created.pane_id
  if type(new_id) ~= "string" then
    return nil, errors.new("backend_error", "herdr pane split: the new pane has no pane_id")
  end

  local start =
    { "herdr", "agent", "start", name, "--kind", tool.name, "--pane", new_id, "--timeout", tostring(START_TIMEOUT_MS) }
  if #tool.cmd > 1 then
    table.insert(start, "--")
    vim.list_extend(start, tool.cmd, 2)
  end
  local agent, start_err = start_agent(start)
  if not agent then
    -- herdr gave up waiting, but a tool in front is alive and only slow: closing the pane would kill it.
    if envelope_code(start_err) == "timeout" then
      local in_front, _, check_err = tool_in_front(new_id, tool)
      if in_front then
        return nil,
          errors.new(
            "backend_error",
            ("herdr started %s but it was not ready after %d ms; pane %s was left open and nothing was sent"):format(
              tool.name,
              START_TIMEOUT_MS,
              new_id
            )
          )
      end
      -- An unreadable pane gives no evidence that a tool is in front, so it is closed and the check's error is kept.
      if check_err then
        start_err.msg = ("%s (checking the foreground of pane %s also failed: %s)"):format(
          start_err.msg,
          new_id,
          check_err.msg
        )
      end
    end
    return close_failed(new_id, start_err)
  end

  -- herdr's answer to `agent start` can lack the cwd, and the agent may not own the foreground yet: the pane was split
  -- in `opts.cwd`, and its shell is recorded.
  local session, session_err = session_of(
    new_id,
    vim.tbl_extend("keep", agent, { cwd = opts.cwd }),
    tool,
    function(info)
      return info.shell_pid
    end
  )
  if not session then
    return close_failed(
      new_id,
      session_err or errors.new("backend_error", ("herdr pane %s has no shell process visible to nvim"):format(new_id))
    )
  end
  return session
end

---Whether the pane's agent is blocked, read fresh. A failed read, or an `agent_status` that is not a known state, is an
---error.
---@param session sidekick_ultra.Session
---@return boolean? blocked
---@return sidekick_ultra.Error? err
local function is_blocked(session)
  local pane, err = query({ "herdr", "pane", "get", session.pane_id }, "pane")
  if not pane then
    return nil, err
  end
  if not STATES[pane.agent_status] then
    return nil, errors.new("backend_error", ("herdr pane %s reported no usable agent_status"):format(session.pane_id))
  end
  return pane.agent_status == "blocked"
end

-- ponytail: the text is one argv element, so it is bounded by the OS argument limit (about 1 MiB on macOS);
-- herdr's CLI has no stdin form, so chunk the text here if that ever matters.
---@param session sidekick_ultra.Session
---@param text string
---@param tool sidekick_ultra.Tool
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.send(session, text, tool)
  local ok, err = contract.guard_send(session, is_blocked)
  if not ok then
    return nil, err
  end
  local in_front, front, front_err = tool_in_front(session.pane_id, tool)
  if in_front == nil then
    return nil, front_err
  end
  if not in_front then
    return nil,
      errors.new(
        "backend_error",
        ("herdr pane %s: %s is not the foreground program (in front: %s); nothing was sent"):format(
          session.pane_id,
          tool.name,
          front
        )
      )
  end
  return exec.check({ "herdr", "pane", "send-text", session.pane_id, text })
end

-- No foreground check, as on tmux: `deliver` stops on a refused send, so Enter never follows one, and no pre-send check
-- can catch a tool that exits while the sent text is still unread.
---@param session sidekick_ultra.Session
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.submit(session)
  return exec.check({ "herdr", "pane", "send-keys", session.pane_id, "Enter" })
end

---`agent focus`, not `pane focus`: the latter focuses a neighbor and needs a direction.
---@param session sidekick_ultra.Session
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.focus(session)
  return exec.check({ "herdr", "agent", "focus", session.pane_id })
end

return M
