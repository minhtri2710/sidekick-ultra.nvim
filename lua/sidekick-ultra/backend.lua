---The contract between the core and a mux backend. A backend is a module that returns a table with these fields;
---`sidekick-ultra.registry` registers it and the core calls it. A backend runs every external command through
---`sidekick-ultra.exec` and reports every failure as a `sidekick_ultra.Error` (usually `backend_error`).
---
---Backend modules live at `sidekick-ultra.backends.<name>`. The names, the options each takes and the facts health
---reports are in the backend table, `sidekick-ultra.backends` (`backends/init.lua`). `setup()` requires the module when
---`<name>.enabled` is true (the default) and registers it only when `available()` returns true.
---A backend gets its options once, through `setup(opts)`, and keeps them in module state until the next `setup()`
---replaces them. It never reads `sidekick-ultra.config`.
local errors = require("sidekick-ultra.errors")

---A running instance of a tool. A plain record: the core never calls methods on it; it passes it back to the
---backend that produced it. Backends may add their own fields (pane or block ids, session ids).
---@class sidekick_ultra.Session
---@field id string `<backend name>:<native id>`, unique across backends
---@field backend string backend `name`
---@field tool string configured tool name
---@field cwd string absolute working directory of the pane or block. A listed pane that runs a tool and reports none
---   fails the listing.
---@field pid? integer foreground process id recorded at discovery. Required unless the backend defines
---   `is_running`, which is then the only liveness check and may work without a pid.
---@field proc_name string foreground process name. Without a backend `is_running`, it must equal `proc.name(pid)`
---   (`sidekick-ultra.proc`), because the liveness rule below compares exactly that. Never copy the mux's own process
---   name (it can differ: truncated on macOS, retitled by the tool, or, for a tool started through a symlink, the name
---   of the file the link points to: Claude Code's `~/.local/bin/claude` points to an executable named by its version);
---   read it in nvim.
---@field state? sidekick_ultra.AgentState last agent state the backend reported

---@alias sidekick_ultra.AgentState "idle"|"working"|"blocked"|"done"|"unknown"

---Where a new session is created. Both fields come from the core.
---@class sidekick_ultra.StartOpts
---@field cwd string nvim's current directory
---@field env table<string, string> the tool's `env`

---@class sidekick_ultra.Backend
---@field name string unique backend name, also the id prefix. When several backends are inside, `start` picks the one
---   whose `name` equals `TERM_PROGRAM`.
---Optional. Called by `setup()` before `available()` with the backend's validated options table (`enabled` and the
---options the backend table lists). A backend that resolves its binary does it here, once, and runs that path
---afterwards.
---@field setup? fun(opts: table)
---Whether the backend can run at all (binary found). Returns the binary path and, when it knows, where the path
---came from (for example "option", "PATH", "bundle"). Used by `setup()` and `:checkhealth`.
---@field available fun(): boolean, string?, string?
---Whether nvim itself runs inside this mux and `start` can create a pane there. Pure environment check; no external
---command.
---@field inside fun(): boolean
---List the sessions of the given tools. Keep only sessions whose foreground program is one of `tools`
---(`proc.tool_of` / `proc.find`, or the backend's own detection). `{}` is a valid answer.
---@field list fun(tools: table<string, sidekick_ultra.Tool>): sidekick_ultra.Session[]?, sidekick_ultra.Error?
---Create a pane or block beside nvim's own, without taking focus, running `tool.cmd`. Only called when `inside()`
---is true. Returns the new session, which passes the liveness rule below at once, so it is not auto-detached before
---the tool has started. A backend that defines `is_running` answers true for the new session, and its record may have
---no `pid` (zellij records the program it parsed as `proc_name`); otherwise the record's `pid` and `proc_name` are
---those of the new pane or block's current foreground (or shell) process, with the name read through
---`proc.name(pid)`. The next discovery replaces the record by id. A start that fails once it has the id of
---the new pane or block either closes it or says in its error that it was left open.
---@field start fun(tool: sidekick_ultra.Tool, opts: sidekick_ultra.StartOpts): sidekick_ultra.Session?, sidekick_ultra.Error?
---Deliver `text` as literal input, with no implicit Enter. `tool` is the session's tool. A backend that reads an agent
---state guards here with `guard_send`; a refusal sends nothing. Returns a truthy value, or nil and the error.
---@field send fun(session: sidekick_ultra.Session, text: string, tool: sidekick_ultra.Tool): any, sidekick_ultra.Error?
---Send Enter. Returns a truthy value, or nil and the error.
---@field submit fun(session: sidekick_ultra.Session): any, sidekick_ultra.Error?
---Bring the session's pane or block to the front of the mux. Returns a truthy value, or nil and the error.
---@field focus fun(session: sidekick_ultra.Session): any, sidekick_ultra.Error?
---Optional. Whether the session still runs, given the session's tool; when defined, it alone decides and the pid and
---name check is not done. It may call the mux through `sidekick-ultra.exec`, so keep it to one cheap call: it runs for
---every attached session each time liveness is checked.
---
---The liveness rule: a session runs when its backend's `is_running` says so, or, without one, when a process with the
---recorded `pid` exists and has the recorded `proc_name`.
---@field is_running? fun(session: sidekick_ultra.Session, tool: sidekick_ultra.Tool): boolean

local M = {}

local FUNCTIONS = { "available", "inside", "list", "start", "send", "submit", "focus" }

---The `send` guard of a backend that reads an agent state. `is_blocked` reads the state fresh and answers whether the
---session waits on a prompt, or nil and the error that kept it from knowing.
---@param session sidekick_ultra.Session
---@param is_blocked fun(session: sidekick_ultra.Session): boolean?, sidekick_ultra.Error?
---@return true? ok nil when `send` must refuse
---@return sidekick_ultra.Error? err `status_unreadable` or `session_blocked`
function M.guard_send(session, is_blocked)
  local blocked, err = is_blocked(session)
  if blocked == nil then
    return nil,
      errors.new("status_unreadable", ("cannot read the state of %s: %s"):format(session.id, err.msg), {
        code = err.code,
      })
  end
  if blocked then
    return nil, errors.new("session_blocked", ("%s (%s) is blocked; nothing was sent"):format(session.tool, session.id))
  end
  return true
end

---Check that `backend` has the shape of `sidekick_ultra.Backend`.
---@param backend any
---@return boolean ok
---@return string? problem
function M.check(backend)
  if type(backend) ~= "table" then
    return false, "backend must be a table"
  end
  if type(backend.name) ~= "string" or backend.name == "" then
    return false, "backend.name must be a non-empty string"
  end
  for _, field in ipairs(FUNCTIONS) do
    if type(backend[field]) ~= "function" then
      return false, ("backend %s: %s must be a function"):format(backend.name, field)
    end
  end
  for _, field in ipairs({ "setup", "is_running" }) do
    if backend[field] ~= nil and type(backend[field]) ~= "function" then
      return false, ("backend %s: %s must be a function"):format(backend.name, field)
    end
  end
  return true
end

return M
