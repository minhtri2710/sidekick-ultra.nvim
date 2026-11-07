---The zellij backend: sessions are terminal panes. zellij 0.45.1 gives no pid for a pane, only `pane_command` (the
---running command line), so a pane is matched to a tool by the basename of that command's first word (argv0), or by
---the script's name when that word is a node or python interpreter, and liveness is a CLI call instead of the
---in-process pid check. The rest of `pane_command` is never kept, logged, or put into an error or a notify. The shapes
---were probed against zellij 0.45.1; what is still unverified is listed in tests/fixtures/zellij/UNVERIFIED.txt.
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")
local proc = require("sidekick-ultra.proc")
local procname = require("sidekick-ultra.procname")

---@type sidekick_ultra.Backend
local M = { name = "zellij" }

-- `start` waits for the new pane to show the tool as its program (the env wrapper and a shell show first): no new
-- list-panes poll starts once START_WAIT_MS have passed since new-pane returned, and polls are START_STEP_MS apart.
local START_WAIT_MS = 2000
local START_STEP_MS = 50

---@return number
local function now()
  return vim.uv.hrtime() / 1e6
end

---@type string?
local bin_path

---@return boolean ok
---@return string? path
---@return string? source
function M.available()
  return exec.on_path("zellij")
end

function M.setup()
  bin_path = select(2, M.available())
end

---`start` needs the session name: `new-pane` runs in nvim's own session.
function M.inside()
  return (vim.env.ZELLIJ or "") ~= ""
    and (vim.env.ZELLIJ_PANE_ID or "") ~= ""
    and (vim.env.ZELLIJ_SESSION_NAME or "") ~= ""
end

---@param session? string
---@param ... string
---@return string[] argv
local function command(session, ...)
  local argv = { bin_path }
  if session then
    vim.list_extend(argv, { "--session", session })
  end
  return vim.list_extend(argv, { ... })
end

---@param session string
---@param ... string
---@return table? res
---@return sidekick_ultra.Error? err
local function run(session, ...)
  return exec.check(command(session, ...))
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
---@return sidekick_ultra.ExecError? err `empty` when zellij exited 0 and printed nothing
local function panes_of(session)
  local decoded, err = exec.json(command(session, "action", "list-panes", "--all", "--json", "--command", "--state"))
  if err then
    -- zellij can exit 0 with nothing printed (the server gives up after 1 s). That is no answer, not "no panes": an
    -- empty list is the text `[]`.
    if err.empty then
      err.msg = "zellij did not answer: list-panes printed nothing"
    end
    return nil, err
  end
  if type(decoded) ~= "table" or not vim.islist(decoded) then
    return nil, errors.new("backend_error", "zellij printed an unexpected pane list")
  end
  local ret = {}
  for _, pane in ipairs(decoded) do
    if type(pane) ~= "table" or type(pane.id) ~= "number" then
      return nil, errors.new("backend_error", "zellij printed an unexpected pane list")
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
      errors.new(
        "backend_error",
        ("zellij printed no working directory for pane %s of session %s"):format(name, session)
      )
  end
  return {
    id = ("%s:%s:%s"):format(M.name, session, name),
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
  local res, err = exec.check(command(nil, "list-sessions", "-n", "-s"))
  if not res then
    if (err.stderr or ""):find("No active zellij sessions", 1, true) then
      return {}
    end
    return nil, err
  end
  -- A successful list-sessions with nothing printed is no answer either: "no session" is exit 1 with a message.
  local names = vim.split(vim.trim(res.stdout), "\n", { plain = true, trimempty = true })
  if #names == 0 then
    return nil, errors.new("backend_error", "zellij did not answer: list-sessions printed nothing")
  end
  return names
end

---ponytail: discovery costs one list-sessions call plus one list-panes call per zellij session. Fine for a handful of
---sessions; batch them when listing gets slow.
---@param configured table<string, sidekick_ultra.Tool>
function M.list(configured)
  local sessions, err
  if M.inside() then
    sessions = { vim.env.ZELLIJ_SESSION_NAME }
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
      if program then
        local name, find_err = proc.find(configured, nil, { program })
        if find_err then
          return nil, find_err
        end
        if name then
          local record, record_err = session_of(name, session, pane, program)
          if not record then
            return nil, record_err
          end
          table.insert(ret, record)
        end
      end
    end
  end
  return ret
end

---Whether the session's pane exists, has not exited, and its current program still satisfies the tool's `is_proc`.
---@param session sidekick_ultra.Session
---@param tool sidekick_ultra.Tool
---@return boolean? alive nil when it could not be told
---@return sidekick_ultra.Error? err
local function alive(session, tool)
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
      if not program then
        return false
      end
      return proc.matches(tool, nil, program)
    end
  end
  return false
end

---ponytail: one list-panes call per attached zellij session per liveness check (`registry.check`, run by the statusline
---refresh and before each action); batch per zellij session if that ever matters.
---A failing CLI call or `is_proc` is not an answer: the session stays attached (a false here detaches it silently), as
---`registry.discover` keeps the attached sessions of a backend that fails. The send guard, which shares `alive`, still
---refuses on an error.
---@param session sidekick_ultra.Session
---@param tool sidekick_ultra.Tool
---@return boolean
function M.is_running(session, tool)
  return alive(session, tool) ~= false
end

---Wait until the new pane `id` shows the tool as its program. An empty answer is asked again within the bound.
---@param tool sidekick_ultra.Tool
---@param session string zellij session name
---@param id integer
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
local function started_session(tool, session, id)
  local deadline = now() + START_WAIT_MS
  local last_err
  while true do
    local panes, panes_err = panes_of(session)
    if not panes then
      if not panes_err.empty then
        return nil, panes_err
      end
      last_err = panes_err
    else
      last_err = nil
      local seen
      for _, pane in ipairs(panes) do
        if pane.id == id then
          seen = pane
          break
        end
      end
      local program = seen and program_of(seen)
      if not program then
        return nil, errors.new("backend_error", ("pane terminal_%d of session %s is not running"):format(id, session))
      end
      local matched, match_err = proc.matches(tool, nil, program)
      if match_err then
        return nil, match_err
      end
      if matched then
        return session_of(tool.name, session, seen, program)
      end
    end
    if now() >= deadline then
      break
    end
    vim.wait(START_STEP_MS)
    if now() >= deadline then
      break
    end
  end
  return nil,
    last_err or errors.new(
      "backend_error",
      ("pane terminal_%d of session %s: its program never showed as %s"):format(id, session, tool.name)
    )
end

---Split a new pane to the right of nvim's own, without focus, running the tool. `new-pane` is placed relative to the
---pane that issued it (`ZELLIJ_PANE_ID`, nvim's). It returns once the pane's program matches the tool, so the session
---is running at once.
---@param tool sidekick_ultra.Tool
---@param opts sidekick_ultra.StartOpts
function M.start(tool, opts)
  local session = vim.env.ZELLIJ_SESSION_NAME
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
  local res, err = run(session, unpack(args))
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
      errors.new(
        "backend_error",
        (
          "zellij printed no id and probably created no pane: it creates none when there is no room in the tab beside "
          .. "nvim's pane, when floating panes are visible there, or when nvim's pane is floating; if it created one "
          .. "anyway, a pane named sku-%s was left open in session %s"
        ):format(tool.name, session)
      )
  end

  local record, record_err = started_session(tool, session, tonumber(number) --[[@as integer]])
  if record_err then
    record_err.msg = ("%s; pane %s of session %s was left open"):format(record_err.msg, name, session)
  end
  return record, record_err
end

---`write-chars` to a missing pane exits 0 and drops the text (probe P-Z7), so check the pane first.
---@param session sidekick_ultra.Session
---@param text string
---@param tool sidekick_ultra.Tool
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.send(session, text, tool)
  local running, err = alive(session, tool)
  if err then
    return nil, err
  end
  if not running then
    return nil,
      errors.new(
        "backend_error",
        ("pane %s of zellij session %s is not running; nothing was sent"):format(session.pane, session.zellij_session)
      )
  end
  return run(session.zellij_session, "action", "write-chars", "--pane-id", session.pane, "--", text)
end

---@param session sidekick_ultra.Session
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.submit(session)
  return run(session.zellij_session, "action", "send-keys", "--pane-id", session.pane, "Enter")
end

---@param session sidekick_ultra.Session
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.focus(session)
  return run(session.zellij_session, "action", "focus-pane-id", session.pane)
end

return M
