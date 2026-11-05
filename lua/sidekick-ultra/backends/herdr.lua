---The herdr backend: sessions are herdr panes whose detected agent kind is a configured tool. nvim talks to the
---server it runs under (`HERDR_SOCKET_PATH` is inherited); no command passes `--session`, `--remote` or `--machine`.
---Every command goes through `sidekick-ultra.exec`. Only pids, names, ids, cwds and states are read from herdr's
---answers, never argv, cmdline or environment.
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")

local M = { name = "herdr" }

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
local START_TIMEOUT_MS = 30000

---@param cmd string subcommand label for a `backend_error`
---@param msg string
---@return sidekick_ultra.Error
local function failure(cmd, msg)
  return errors.new("backend_error", msg, { backend = M.name, cmd = cmd })
end

---Run `argv`, decode herdr's `{id, result = {type, ...}}` envelope and return `result[field]`, a table.
---@param argv string[]
---@param cmd string
---@param field string
---@return table? payload
---@return sidekick_ultra.Error? err
local function query(argv, cmd, field)
  local res, err = exec.json(argv, { backend = M.name, cmd = cmd })
  if res == nil then
    return nil, err
  end
  local payload = type(res) == "table" and type(res.result) == "table" and res.result[field]
  if type(payload) ~= "table" then
    return nil, failure(cmd, ("herdr %s: response has no result.%s"):format(cmd, field))
  end
  return payload
end

---Run a command whose success carries no data we use.
---@param argv string[]
---@param cmd string
---@return true? ok
---@return sidekick_ultra.Error? err
local function run(argv, cmd)
  local _, err = exec.check(argv, { backend = M.name, cmd = cmd })
  if err then
    return nil, err
  end
  return true
end

---The pid of the foreground process: the `foreground_processes` entry whose pid is the foreground process group,
---else the first one.
---@param info table a `PaneProcessInfo`
---@return integer? pid
local function foreground_pid(info)
  local processes = type(info.foreground_processes) == "table" and info.foreground_processes or {}
  local chosen = processes[1]
  for _, process in ipairs(processes) do
    if type(process) == "table" and process.pid == info.foreground_process_group_id then
      chosen = process
      break
    end
  end
  return type(chosen) == "table" and chosen.pid or nil
end

---The pid of the pane's shell, which lives as long as the pane.
---@param info table a `PaneProcessInfo`
---@return integer? pid
local function shell_pid(info)
  return info.shell_pid
end

---A pane's process chosen by `pick`, with the name this machine's process table gives that pid: the value
---`is_running` compares against later. Returns nothing when `pick` finds no pid or the pid is not visible here.
---@param pane_id string
---@param pick fun(info: table): integer?
---@return integer? pid
---@return string? proc_name
---@return sidekick_ultra.Error? err
local function recorded_process(pane_id, pick)
  local info, err = query({ "herdr", "pane", "process-info", "--pane", pane_id }, "pane process-info", "process_info")
  if not info then
    return nil, nil, err
  end
  local pid = pick(info)
  if type(pid) ~= "number" then
    return nil
  end
  local ok, proc = pcall(vim.api.nvim_get_proc, pid)
  if not ok or type(proc) ~= "table" or type(proc.name) ~= "string" then
    return nil
  end
  return pid, proc.name
end

---Build a session from a `PaneInfo` or `AgentInfo`. Returns nothing (no session, no error) when the pane has no
---cwd or the picked process is not running on this machine.
---@param pane_id string
---@param info table
---@param tool sidekick_ultra.Tool
---@param pick fun(info: table): integer? foreground_pid for discovery, shell_pid for a pane just started
---@param fallback_cwd? string used when herdr reports no cwd
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
local function session_of(pane_id, info, tool, pick, fallback_cwd)
  local cwd = info.foreground_cwd or info.cwd or fallback_cwd
  if type(cwd) ~= "string" then
    return nil
  end
  local pid, proc_name, err = recorded_process(pane_id, pick)
  if not pid then
    return nil, err
  end
  return {
    id = "herdr:" .. pane_id,
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
  local path = vim.fn.exepath("herdr")
  if path == "" then
    return false
  end
  return true, path, "PATH"
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
  -- Without --workspace herdr lists the panes of every workspace.
  local panes, err = query({ "herdr", "pane", "list" }, "pane list", "panes")
  if not panes then
    return nil, err
  end
  local sessions = {}
  for _, pane in ipairs(panes) do
    if type(pane) ~= "table" or type(pane.pane_id) ~= "string" then
      return nil, failure("pane list", "herdr pane list: a pane has no pane_id")
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

---`sku-<tool>-<n>` with the lowest positive n that no existing herdr agent uses.
---@param tool_name string
---@return string? name
---@return sidekick_ultra.Error? err
local function agent_name(tool_name)
  local agents, err = query({ "herdr", "agent", "list" }, "agent list", "agents")
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

---Run `herdr agent start`. It prints an error envelope on stderr and exits 1 when the agent does not become ready
---(`print_response`, src/cli.rs:745-749). `agent_not_ready` (src/cli/agent.rs:608-611) means the agent started but is
---blocked during startup, for example on a trust prompt: it is running, so it counts as started with state
---blocked. Any other failure is a `backend_error`.
---@param argv string[]
---@return table? agent the started agent's `AgentInfo`, or `{agent_status = "blocked"}` for `agent_not_ready`
---@return sidekick_ultra.Error? err
local function start_agent(argv)
  local cmd = "agent start"
  local res, err =
    exec.run(argv, { backend = M.name, cmd = cmd, timeout_ms = START_TIMEOUT_MS + exec.DEFAULT_TIMEOUT_MS })
  if not res then
    return nil, err
  end
  if res.code == 0 then
    local ok, decoded = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
    local agent = ok and type(decoded) == "table" and type(decoded.result) == "table" and decoded.result.agent
    if type(agent) ~= "table" then
      return nil, failure(cmd, "herdr agent start: response has no result.agent")
    end
    return agent
  end
  local first = vim.split(res.stderr, "\n", { plain = true })[1]
  local ok, decoded = pcall(vim.json.decode, first, { luanil = { object = true, array = true } })
  local code = ok and type(decoded) == "table" and type(decoded.error) == "table" and decoded.error.code
  if code == "agent_not_ready" then
    return { agent_status = "blocked" }
  end
  local msg = ("herdr exited with %d"):format(res.code)
  return nil,
    errors.new("backend_error", first ~= "" and (msg .. ": " .. first) or msg, {
      backend = M.name,
      cmd = cmd,
      code = res.code,
    })
end

---@param tool sidekick_ultra.Tool
---@param opts sidekick_ultra.StartOpts
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
function M.start(tool, opts)
  local own = vim.env.HERDR_PANE_ID
  if own == nil or own == "" then
    return nil, errors.new("not_in_mux", "nvim does not run inside herdr; cannot start a tool")
  end
  local executable = vim.tbl_contains(KINDS, tool.name) and (EXECUTABLE[tool.name] or tool.name) or nil
  if not executable then
    return nil, failure("agent start", ("herdr has no agent kind named %s"):format(tool.name))
  end
  -- herdr launches its own executable for the kind and gets only the arguments, so another command would be ignored.
  if tool.cmd[1] ~= executable then
    return nil,
      failure(
        "agent start",
        ("herdr starts `%s` for %s, but the tool command is `%s`"):format(executable, tool.name, tool.cmd[1])
      )
  end
  local name, err = agent_name(tool.name)
  if not name then
    return nil, err
  end

  local split = { "herdr", "pane", "split", "--pane", own, "--direction", "right", "--cwd", opts.cwd }
  local keys = vim.tbl_keys(opts.env)
  table.sort(keys)
  for _, key in ipairs(keys) do
    vim.list_extend(split, { "--env", key .. "=" .. opts.env[key] })
  end
  table.insert(split, "--no-focus")
  local created, split_err = query(split, "pane split", "pane")
  if not created then
    return nil, split_err
  end
  local new_id = created.pane_id
  if type(new_id) ~= "string" then
    return nil, failure("pane split", "herdr pane split: the new pane has no pane_id")
  end

  local start =
    { "herdr", "agent", "start", name, "--kind", tool.name, "--pane", new_id, "--timeout", tostring(START_TIMEOUT_MS) }
  if #tool.cmd > 1 then
    table.insert(start, "--")
    vim.list_extend(start, tool.cmd, 2)
  end
  local agent, start_err = start_agent(start)
  if not agent then
    -- The only cleanup, for every failure except agent_not_ready: close the pane this call just created.
    local closed, close_err = run({ "herdr", "pane", "close", new_id }, "pane close")
    if not closed then
      start_err.msg = ("%s (closing the new pane %s also failed: %s)"):format(start_err.msg, new_id, close_err.msg)
    end
    return nil, start_err
  end

  -- The agent may not own the foreground yet, so record the pane's shell: it is running at once and as long as the
  -- pane. The next discovery replaces the record with the agent's foreground process.
  local session, session_err = session_of(new_id, agent, tool, shell_pid, opts.cwd)
  if not session then
    return nil,
      session_err or failure("agent start", ("herdr pane %s has no shell process visible to nvim"):format(new_id))
  end
  return session
end

---The pane's `agent_status`, read fresh. A failed or unrecognizable read is `status_unreadable`.
---@param session sidekick_ultra.Session
---@return sidekick_ultra.AgentState? state
---@return sidekick_ultra.Error? err
local function read_state(session)
  local pane, err = query({ "herdr", "pane", "get", session.pane_id }, "pane get", "pane")
  if not pane then
    return nil,
      errors.new("status_unreadable", "cannot read the state of herdr pane " .. session.pane_id .. ": " .. err.msg, {
        backend = M.name,
        cmd = "pane get",
        code = err.code,
      })
  end
  if not STATES[pane.agent_status] then
    return nil,
      errors.new("status_unreadable", "herdr pane " .. session.pane_id .. " reported no usable agent_status", {
        backend = M.name,
        cmd = "pane get",
      })
  end
  return pane.agent_status
end

-- ponytail: the text is one argv element, so it is bounded by the OS argument limit (about 1 MiB on macOS);
-- herdr's CLI has no stdin form, so chunk the text here if that ever matters.
---@param session sidekick_ultra.Session
---@param text string
---@return true? ok
---@return sidekick_ultra.Error? err
function M.send(session, text)
  if text == "" then
    return true
  end
  local state, err = read_state(session)
  if not state then
    return nil, err
  end
  if state == "blocked" then
    return nil,
      errors.new(
        "session_blocked",
        ("%s in herdr pane %s is blocked; nothing was sent"):format(session.tool, session.pane_id),
        {
          backend = M.name,
          session_id = session.id,
        }
      )
  end
  return run({ "herdr", "pane", "send-text", session.pane_id, text }, "pane send-text")
end

---@param session sidekick_ultra.Session
---@return true? ok
---@return sidekick_ultra.Error? err
function M.submit(session)
  return run({ "herdr", "pane", "send-keys", session.pane_id, "Enter" }, "pane send-keys")
end

---`agent focus`, not `pane focus`: the latter focuses a neighbor and needs a direction.
---@param session sidekick_ultra.Session
---@return true? ok
---@return sidekick_ultra.Error? err
function M.focus(session)
  return run({ "herdr", "agent", "focus", session.pane_id }, "agent focus")
end

return M
