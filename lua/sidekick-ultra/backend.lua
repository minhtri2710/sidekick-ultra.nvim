---The contract between the core and a mux backend (herdr, rex, tmux, zellij). A backend is a module that returns a table with
---these fields; `sidekick-ultra.registry` registers it and the core calls it. A backend runs every external command
---through `sidekick-ultra.exec` and reports every failure as a `sidekick_ultra.Error` (usually `backend_error`).
---
---Backend modules live at `sidekick-ultra.backends.<name>` and are required by `setup()` when `<name>.enabled` is
---true (the default). `setup()` registers the module only when `available()` returns true.
---Run commands with `exec.run` / `exec.check` / `exec.json` (`opts.backend` and `opts.cmd` name the backend and the
---subcommand in the resulting `backend_error`); build errors with `errors.new(id, msg, extra)`.
---A backend reads its own options from `require("sidekick-ultra.config").get()[name]` (`herdr = {enabled}`,
---`rex = {enabled, bin, server}`, `tmux = {enabled, socket}`, `zellij = {enabled}`); the core only validates them.

---A running instance of a tool. A plain record: the core never calls methods on it; it passes it back to the
---backend that produced it. Backends may add their own fields (pane or block ids, session ids).
---@class sidekick_ultra.Session
---@field id string `<backend>:<native id>`, unique across backends (`herdr:<pane_id>`, `rex:<block_id>`, `tmux:%N`)
---@field backend string backend `name`
---@field tool string configured tool name
---@field cwd string absolute working directory of the pane or block
---@field pid? integer foreground process id recorded at discovery. Required unless the backend defines
---   `is_running`, which is then the only liveness check and may work without a pid.
---@field proc_name string foreground process name. Without a backend `is_running`, it must equal
---   `vim.api.nvim_get_proc(pid).name` as nvim reads it at discovery time, because `registry.is_running` compares
---   exactly that. Never copy the mux's own process name (it can differ: truncated on macOS, or retitled by the
---   tool); read it in nvim.
---@field state? sidekick_ultra.AgentState last agent state the backend reported
---@field sid? string `<tool> <hex>`; set by the registry on discovery, backends leave it nil

---@alias sidekick_ultra.AgentState "idle"|"working"|"blocked"|"done"|"unknown"

---Where a new session is created. Both fields come from the core.
---@class sidekick_ultra.StartOpts
---@field cwd string nvim's current directory
---@field env table<string, string> the tool's `env`

---@class sidekick_ultra.Backend
---@field name string unique backend name, also the id prefix. When several backends are inside, `start` picks the one
---   whose `name` equals `TERM_PROGRAM`: herdr, rex and tmux set it to their name, zellij does not set it.
---Whether the backend can run at all (binary found). Returns the binary path and, when it knows, where the path
---came from (for example "option", "PATH", "bundle"). Used by `setup()` and `:checkhealth`.
---@field available fun(): boolean, string?, string?
---Whether nvim itself runs inside this mux. Pure environment check; no external command.
---@field inside fun(): boolean
---List the sessions of the given tools. Keep only sessions whose foreground program is one of `tools`
---(`tools.matches(tool, {pid = ..., cmd = ...})`, or the backend's own detection). `{}` is a valid answer.
---@field list fun(tools: table<string, sidekick_ultra.Tool>): sidekick_ultra.Session[]?, sidekick_ultra.Error?
---Create a pane or block beside nvim's own, without taking focus, running `tool.cmd`. Only called when `inside()`
---is true. Returns the new session. Its `pid` and `proc_name` are those of the new pane or block's current
---foreground (or shell) process, with the name read through `vim.api.nvim_get_proc(pid)`, so the session counts as
---running at once and is not auto-detached before the tool has started. The next discovery replaces the record by id.
---@field start fun(tool: sidekick_ultra.Tool, opts: sidekick_ultra.StartOpts): sidekick_ultra.Session?, sidekick_ultra.Error?
---Deliver `text` as literal input, with no implicit Enter. The blocked guard lives here: re-read the session's
---state first, and refuse with `session_blocked` when it is blocked or `status_unreadable` when the state cannot
---be read. A refusal must send nothing.
---@field send fun(session: sidekick_ultra.Session, text: string): true?, sidekick_ultra.Error?
---Send Enter.
---@field submit fun(session: sidekick_ultra.Session): true?, sidekick_ultra.Error?
---Bring the session's pane or block to the front of the mux.
---@field focus fun(session: sidekick_ultra.Session): true?, sidekick_ultra.Error?
---Optional. Whether the session still runs; when defined, `registry.is_running` returns its result and never does the
---pid and name check. It may call the mux through `sidekick-ultra.exec`. It runs on every status refresh (at most every
---5 s) and when attached sessions are listed, so keep it to a single cheap call. Backends without it need `pid`.
---@field is_running? fun(session: sidekick_ultra.Session): boolean

local M = {}

local FUNCTIONS = { "available", "inside", "list", "start", "send", "submit", "focus" }

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
  if backend.is_running ~= nil and type(backend.is_running) ~= "function" then
    return false, ("backend %s: is_running must be a function"):format(backend.name)
  end
  return true
end

return M
