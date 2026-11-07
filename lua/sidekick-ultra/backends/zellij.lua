---The zellij backend: sessions are terminal panes. zellij 0.45.1 gives no pid for a pane, only `pane_command` (the
---running command line), so a pane is matched to a tool by the basename of that command's first word (argv0), or by
---the script's name when that word is a node or python interpreter, and liveness is a CLI call instead of the
---in-process pid check. The rest of `pane_command` is never kept, logged, or put into an error or a notify. The shapes
---were probed in D8; what is still unverified is listed in tests/fixtures/zellij/UNVERIFIED.txt.
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")
local proc = require("sidekick-ultra.proc")
local procname = require("sidekick-ultra.procname")
local tools = require("sidekick-ultra.tools")

---@type sidekick_ultra.Backend
local M = { name = "zellij" }

-- `start` waits for the new pane to show the tool as its program (the env wrapper and a shell show first): no new
-- list-panes poll starts once START_WAIT_MS have passed since new-pane returned, and polls are START_STEP_MS apart.
local START_WAIT_MS = 2000
local START_STEP_MS = 50

---Milliseconds on a monotonic clock. A field with `wait`, so tests can drive both with a fake clock.
M.now = function()
  return vim.uv.hrtime() / 1e6
end

---Wait `ms` while the event loop keeps running (the exec calls of this backend already do the same through
---`vim.system():wait()`).
M.wait = function(ms)
  vim.wait(ms)
end

---@return boolean ok
---@return string? path
---@return string? source
function M.available()
  return exec.on_path("zellij")
end

function M.inside()
  return (vim.env.ZELLIJ or "") ~= "" and (vim.env.ZELLIJ_PANE_ID or "") ~= ""
end

---@param label string
---@param msg string
---@return sidekick_ultra.Error
local function failure(label, msg)
  return errors.new("backend_error", msg, { backend = M.name, cmd = label })
end

---@param label string subcommand label for errors
---@param session? string
---@param ... string
---@return string[]? argv
---@return table|sidekick_ultra.Error opts exec options, or the error when zellij cannot be found
local function command(label, session, ...)
  local ok, bin = M.available()
  if not ok then
    return nil, failure(label, "zellij binary not found")
  end
  local argv = { bin }
  if session then
    vim.list_extend(argv, { "--session", session })
  end
  vim.list_extend(argv, { ... })
  return argv, { backend = M.name, cmd = label }
end

---@param label string
---@param session string
---@param ... string
---@return table? res
---@return sidekick_ultra.Error? err
local function run(label, session, ...)
  local argv, opts = command(label, session, ...)
  if not argv then
    return nil, opts
  end
  return exec.check(argv, opts)
end

---The program of a `pane_command`: the basename of its first word, or the script's name when that word is a node or
---python interpreter (see procname). The rest of the line is dropped here and never seen again.
---@param pane table
---@return string? program
local function program_of(pane)
  local line = pane.pane_command
  return type(line) == "string" and procname.program(line) or nil
end

---The terminal panes of a session that still run something: plugin panes (they share ids with terminal panes) and
---exited panes are dropped.
---@param session string
---@return table[]? panes
---@return sidekick_ultra.Error? err
---@return boolean? silent true when zellij exited 0 and printed nothing (no answer, worth asking again)
local function panes_of(session)
  local argv, opts = command("list-panes", session, "action", "list-panes", "--all", "--json", "--command", "--state")
  if not argv then
    return nil, opts
  end
  local res, err = exec.check(argv, opts)
  if not res then
    return nil, err
  end
  -- zellij can exit 0 with nothing printed (the server gives up after 1 s). That is no answer, not "no panes": an
  -- empty list is the text `[]`.
  if vim.trim(res.stdout) == "" then
    return nil, failure("list-panes", "zellij did not answer: list-panes printed nothing"), true
  end
  local ok, decoded = exec.decode(res.stdout)
  if not ok then
    return nil, failure("list-panes", "zellij printed invalid JSON")
  end
  if type(decoded) ~= "table" or not vim.islist(decoded) then
    return nil, failure("list-panes", "zellij printed an unexpected pane list")
  end
  local ret = {}
  for _, pane in ipairs(decoded) do
    if type(pane) ~= "table" or type(pane.id) ~= "number" then
      return nil, failure("list-panes", "zellij printed an unexpected pane list")
    end
    if pane.is_plugin ~= true and pane.exited ~= true then
      table.insert(ret, pane)
    end
  end
  return ret
end

---@param err sidekick_ultra.ExecError
---@return boolean
local function session_gone(err)
  return err.code == 1 and err.stderr:find("Session '", 1, true) ~= nil and err.stderr:find("not found", 1, true) ~= nil
end

---Session record for a pane. `program` is informational: `is_running` asks the tool's `is_proc`.
---@param tool_name string
---@param session string zellij session name
---@param pane table
---@param program string
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
local function session_of(tool_name, session, pane, program)
  local name = "terminal_" .. pane.id
  if type(pane.pane_cwd) ~= "string" or pane.pane_cwd == "" then
    return nil,
      failure("list-panes", ("zellij printed no working directory for pane %s of session %s"):format(name, session))
  end
  return {
    id = ("zellij:%s:%s"):format(session, name),
    backend = M.name,
    tool = tool_name,
    cwd = pane.pane_cwd,
    proc_name = program,
    zellij_session = session,
    pane = name,
  }
end

---@return string[]? names
---@return sidekick_ultra.Error? err
local function session_names()
  local argv, opts = command("list-sessions", nil, "list-sessions", "-n", "-s")
  if not argv then
    return nil, opts
  end
  local res, err = exec.run(argv, opts)
  if not res then
    return nil, err
  end
  if res.code ~= 0 then
    if res.stdout == "" and res.stderr:find("No active zellij sessions", 1, true) then
      return {}
    end
    return nil, exec.result_error(argv, res, opts)
  end
  -- A successful list-sessions with nothing printed is no answer either: "no session" is exit 1 with a message.
  local names = vim.split(vim.trim(res.stdout), "\n", { plain = true, trimempty = true })
  if #names == 0 then
    return nil, failure("list-sessions", "zellij did not answer: list-sessions printed nothing")
  end
  return names
end

---ponytail: discovery costs one list-sessions call plus one list-panes call per zellij session. Fine for a handful of
---sessions; batch them when listing gets slow.
---@param configured table<string, sidekick_ultra.Tool>
function M.list(configured)
  local own = M.inside() and vim.env.ZELLIJ_SESSION_NAME or ""
  local sessions, err
  if own ~= "" then
    sessions = { own }
  else
    sessions, err = session_names()
    if not sessions then
      return nil, err
    end
  end
  local ret = {}
  for _, session in ipairs(sessions) do
    local panes, panes_err = panes_of(session)
    if not panes then
      -- A session that vanished since list-sessions (or that can only be resurrected) has no panes to list.
      if not session_gone(panes_err) then
        return nil, panes_err
      end
      panes = {}
    end
    for _, pane in ipairs(panes) do
      local program = program_of(pane)
      local name = program and proc.find(configured, nil, { program })
      if name then
        local record, record_err = session_of(name, session, pane, program)
        if not record then
          return nil, record_err
        end
        table.insert(ret, record)
      end
    end
  end
  return ret
end

---Whether the session's pane exists, has not exited, and its current program still satisfies the tool's `is_proc`.
---Not an equality with `proc_name`: the tool's `is_proc` decides.
---@param session sidekick_ultra.Session
---@return boolean? alive
---@return sidekick_ultra.Error? err
local function alive(session)
  local tool = tools.get(session.tool)
  if not tool then
    return false
  end
  local panes, err = panes_of(session.zellij_session)
  if not panes then
    if session_gone(err) then
      return false
    end
    return nil, err
  end
  for _, pane in ipairs(panes) do
    if "terminal_" .. pane.id == session.pane then
      local program = program_of(pane)
      return program ~= nil and proc.matches(tool, nil, program)
    end
  end
  return false
end

---ponytail: one list-panes call per attached zellij session per refresh (status refresh and attach-time pruning);
---batch per zellij session if that ever matters.
---A failing CLI call is not an answer: the session stays attached (a false here detaches it silently), as
---`registry.discover` keeps the attached sessions of a backend that fails. The send guard, which shares `alive`, still
---refuses on an error.
---@param session sidekick_ultra.Session
---@return boolean
function M.is_running(session)
  return alive(session) ~= false
end

---Split a new pane to the right of nvim's own, without focus, running the tool. `new-pane` is placed relative to the
---pane that issued it (`ZELLIJ_PANE_ID`, nvim's). It has no env flag, so a non-empty `opts.env` goes in front of the
---command as `/usr/bin/env K=V`. It returns once the pane's program matches the tool (see the wait below), so the
---session is running at once. The registry focuses the new pane.
---@param tool sidekick_ultra.Tool
---@param opts sidekick_ultra.StartOpts
function M.start(tool, opts)
  local session = vim.env.ZELLIJ_SESSION_NAME or ""
  if session == "" then
    return nil, failure("new-pane", "ZELLIJ_SESSION_NAME is not set")
  end
  local args = {
    "action",
    "new-pane",
    "--direction",
    "right",
    "--no-focus",
    "--cwd",
    opts.cwd,
    "--name",
    "sku-" .. tool.name,
    "--",
  }
  vim.list_extend(args, exec.env_prefix(opts.env))
  vim.list_extend(args, tool.cmd)
  local res, err = run("new-pane", session, unpack(args))
  if not res then
    return nil, err
  end
  local name = vim.trim(res.stdout)
  local number = name:match("^terminal_(%d+)$")
  if not number then
    -- zellij prints the id only once it has made the pane. It makes none, silently and with exit 0, when the tab has no
    -- room for the split, when floating panes are visible there, or when nvim's own pane is floating (zellij-server
    -- tab/mod.rs). A slow server (it waits 1 s for the pane) can also print nothing for a pane it did create. The text
    -- is true in every case.
    return nil,
      failure(
        "new-pane",
        (
          "zellij printed no id and probably created no pane: it creates none when there is no room in the tab beside "
          .. "nvim's pane, when floating panes are visible there, or when nvim's pane is floating; if it created one "
          .. "anyway, a pane named sku-%s was left open in session %s"
        ):format(tool.name, session)
      )
  end

  -- Return only once the pane shows the tool as its program, so the session is running at once: the env wrapper, a
  -- shell or a script's interpreter show first. An empty answer is asked again within the bound.
  local deadline = M.now() + START_WAIT_MS
  local last_err
  while true do
    local panes, panes_err, silent = panes_of(session)
    if not panes then
      if not silent then
        return nil, panes_err
      end
      last_err = panes_err
    else
      last_err = nil
      local seen
      for _, pane in ipairs(panes) do
        if pane.id == tonumber(number) then
          seen = pane
          break
        end
      end
      local program = seen and program_of(seen)
      if not program then
        return nil,
          failure("new-pane", ("pane %s of session %s is not running; it was left open"):format(name, session))
      end
      if proc.matches(tool, nil, program) then
        return session_of(tool.name, session, seen, program)
      end
    end
    if M.now() >= deadline then
      break
    end
    M.wait(START_STEP_MS)
    if M.now() >= deadline then
      break
    end
  end
  return nil,
    last_err or failure(
      "new-pane",
      ("pane %s of session %s was left open; its program never showed as %s"):format(name, session, tool.name)
    )
end

---`write-chars` to a missing pane exits 0 and drops the text (probe P-Z7), so check the pane first. This takes the
---place of the blocked-status guard of the other backends: zellij has no agent status.
---@param session sidekick_ultra.Session
---@param text string
function M.send(session, text)
  local running, err = alive(session)
  if err then
    return nil, err
  end
  if not running then
    return nil,
      failure(
        "write-chars",
        ("pane %s of zellij session %s is not running; nothing was sent"):format(session.pane, session.zellij_session)
      )
  end
  local res, send_err =
    run("write-chars", session.zellij_session, "action", "write-chars", "--pane-id", session.pane, "--", text)
  if not res then
    return nil, send_err
  end
  return true
end

---@param session sidekick_ultra.Session
function M.submit(session)
  local res, err = run("send-keys", session.zellij_session, "action", "send-keys", "--pane-id", session.pane, "Enter")
  if not res then
    return nil, err
  end
  return true
end

---@param session sidekick_ultra.Session
function M.focus(session)
  local res, err = run("focus-pane-id", session.zellij_session, "action", "focus-pane-id", session.pane)
  if not res then
    return nil, err
  end
  return true
end

return M
