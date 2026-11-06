---Backends, discovered sessions, the attached set and the attach/detach events. All mutable core state lives here
---(plus the watch handles it switches on and off); `reset()` clears it for tests.
local backend_contract = require("sidekick-ultra.backend")
local errors = require("sidekick-ultra.errors")
local tools = require("sidekick-ultra.tools")
local watch = require("sidekick-ultra.watch")

local M = {}

M.ATTACH = "SidekickUltraAttach"
M.DETACH = "SidekickUltraDetach"

---@type sidekick_ultra.Backend[]
local backends = {}
---@type table<string, sidekick_ultra.Session>
local attached = {}

---@param backend sidekick_ultra.Backend
function M.register(backend)
  local ok, problem = backend_contract.check(backend)
  if not ok then
    error("sidekick-ultra: " .. problem, 2)
  end
  if M.backend(backend.name) then
    error("sidekick-ultra: backend already registered: " .. backend.name, 2)
  end
  table.insert(backends, backend)
end

---@param name string
---@return sidekick_ultra.Backend?
function M.backend(name)
  for _, backend in ipairs(backends) do
    if backend.name == name then
      return backend
    end
  end
end

---Forget all backends and attached sessions and stop watching.
function M.reset()
  backends = {}
  attached = {}
  watch.stop()
end

---`<tool> <hex>`: the first `16 - #tool` characters of the sha256 of the normalized absolute cwd.
---@param tool string
---@param cwd string
---@return string
function M.sid(tool, cwd)
  local path = vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p"))
  if #path > 1 then
    path = path:gsub("/+$", "")
  end
  return tool .. " " .. vim.fn.sha256(path):sub(1, 16 - #tool)
end

---Whether the session still runs. A backend that defines `is_running` decides (it may call its mux); otherwise this
---is true when a process with the recorded pid exists and has the recorded name, with no external call.
---@param session sidekick_ultra.Session
---@return boolean
function M.is_running(session)
  local backend = M.backend(session.backend)
  if backend and backend.is_running then
    return backend.is_running(session)
  end
  local ok, proc = pcall(vim.api.nvim_get_proc, session.pid)
  return ok and type(proc) == "table" and proc.name == session.proc_name
end

---@param event string
---@param id string
local function fire(event, id)
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", { pattern = event, data = { id = id }, modeline = false })
  end)
end

---Add a session to the attached set. Does nothing and returns false when its id is already attached.
---@param session sidekick_ultra.Session
---@return boolean attached
function M.attach(session)
  if attached[session.id] then
    return false
  end
  attached[session.id] = session
  watch.update(true)
  fire(M.ATTACH, session.id)
  return true
end

---@param id string
---@return sidekick_ultra.Session? session the detached session, nil when it was not attached
function M.detach(id)
  local session = attached[id]
  if not session then
    return nil
  end
  attached[id] = nil
  watch.update(next(attached) ~= nil)
  fire(M.DETACH, id)
  return session
end

---Detach every attached session, firing the detach events (running or not).
function M.detach_all()
  local ids = vim.tbl_keys(attached)
  table.sort(ids)
  for _, id in ipairs(ids) do
    M.detach(id)
  end
end

---The attached sessions sorted by id. A session that fails the running check may only be a record taken at start
---(a launcher or shell that became the tool), so one `discover()` first replaces the records by id; sessions that
---still fail the check are then detached. With every check passing there is no discovery.
---@return sidekick_ultra.Session[] attached
---@return sidekick_ultra.Session[]? discovered what that discovery listed, nil when none ran
function M.attached()
  local ids = vim.tbl_keys(attached)
  table.sort(ids)
  local failing = vim.tbl_filter(function(id)
    return not M.is_running(attached[id])
  end, ids)
  local discovered
  if #failing > 0 then
    discovered = M.discover()
  end
  local ret = {}
  for _, id in ipairs(ids) do
    local session = attached[id]
    if session and (not vim.tbl_contains(failing, id) or M.is_running(session)) then
      table.insert(ret, session)
    else
      M.detach(id)
    end
  end
  return ret, discovered
end

---Ask every backend for its sessions. A backend that fails reports its error once and contributes nothing (its
---attached sessions stay attached). A duplicate id is reported and the first session is kept. Afterwards attached
---entries are refreshed from the listing, and attached ids that are gone from a backend that listed are detached.
---@return sidekick_ultra.Session[]
function M.discover()
  local ret, by_id, failed = {}, {}, {}
  for _, backend in ipairs(backends) do
    local ok, list, err = pcall(backend.list, tools.all())
    if not ok then
      list, err = nil, errors.new("backend_error", tostring(list), { backend = backend.name, cmd = "list" })
    end
    if list then
      for _, session in ipairs(list) do
        if by_id[session.id] then
          errors.notify(
            errors.new("duplicate_session", "duplicate session id " .. session.id, { session_id = session.id })
          )
        else
          session.sid = M.sid(session.tool, session.cwd)
          by_id[session.id] = session
          table.insert(ret, session)
        end
      end
    else
      failed[backend.name] = true
      errors.notify(err)
    end
  end
  for id, old in pairs(attached) do
    if by_id[id] then
      attached[id] = by_id[id]
    elseif not failed[old.backend] then
      M.detach(id)
    end
  end
  return ret
end

---The backend `start` uses: among the registered backends whose `inside()` is true, the only one, or with several
---the one named by `TERM_PROGRAM`. Anything else is `not_in_mux`.
---@return sidekick_ultra.Backend? backend
---@return sidekick_ultra.Error? err
function M.start_backend()
  local inside = vim.tbl_filter(function(backend)
    return backend.inside()
  end, backends)
  if #inside == 1 then
    return inside[1]
  end
  if #inside > 1 then
    local term = vim.env.TERM_PROGRAM
    for _, backend in ipairs(inside) do
      if backend.name == term then
        return backend
      end
    end
  end
  return nil, errors.new("not_in_mux", "nvim does not run inside a supported multiplexer; cannot start a tool")
end

---Create a session of `tool` next to nvim through the selected backend and focus it unless `opts.focus == false`.
---A focus refusal is notified; the session is still returned. Does not attach it.
---@param tool sidekick_ultra.Tool
---@param opts? { focus?: boolean }
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
function M.start(tool, opts)
  local backend, err = M.start_backend()
  if not backend then
    return nil, err
  end
  local session, start_err = backend.start(tool, { cwd = vim.fn.getcwd(), env = vim.deepcopy(tool.env) })
  if not session then
    return nil, start_err
  end
  session.sid = M.sid(session.tool, session.cwd)
  if not (opts and opts.focus == false) then
    local ok, focus_err = backend.focus(session)
    if not ok then
      errors.notify(focus_err)
    end
  end
  return session
end

return M
