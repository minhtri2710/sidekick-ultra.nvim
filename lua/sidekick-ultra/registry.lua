---The registered backends, the attached sessions, discovery of sessions through the backends, and the attach and
---detach events. It knows nothing of `target` or `actions` above it; `status` and `watch` subscribe to the events.
local backend_contract = require("sidekick-ultra.backend")
local errors = require("sidekick-ultra.errors")
local proc = require("sidekick-ultra.proc")
local tools = require("sidekick-ultra.tools")

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

---Detach every attached session, firing the detach events, and forget all backends.
function M.reset()
  M.detach_all()
  backends = {}
end

---Whether the session still runs: the rule is in `backend.lua`.
---@param session sidekick_ultra.Session session of a registered backend
---@return boolean
function M.is_running(session)
  local is_running = M.backend(session.backend).is_running
  if is_running then
    return is_running(session)
  end
  return proc.name(session.pid) == session.proc_name
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

---The attached sessions sorted by id. No side effects: `check` and `discover` detach the ones that stopped.
---@return sidekick_ultra.Session[]
function M.attached()
  local ids = vim.tbl_keys(attached)
  table.sort(ids)
  return vim.tbl_map(function(id)
    return attached[id]
  end, ids)
end

---Ask every backend for its sessions. A backend that fails reports its error once and contributes nothing. A
---duplicate id is reported and the first session is kept. Then each attached session is replaced by its listed
---record, and detached when a backend that listed no longer lists it or when it still fails `is_running`.
---@return sidekick_ultra.Session[] listed
function M.discover()
  local listed, by_id, failed = {}, {}, {}
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
          by_id[session.id] = session
          table.insert(listed, session)
        end
      end
    else
      failed[backend.name] = true
      errors.notify(err)
    end
  end
  for _, old in ipairs(M.attached()) do
    local session = by_id[old.id] or old
    if (not by_id[old.id] and not failed[old.backend]) or not M.is_running(session) then
      M.detach(old.id)
    else
      attached[old.id] = session
    end
  end
  return listed
end

---Run the liveness check on every attached session. The first failure runs one `discover()`, which replaces the
---records and detaches what is gone. With every check passing no backend is listed.
function M.check()
  for _, session in ipairs(M.attached()) do
    if not M.is_running(session) then
      M.discover()
      return
    end
  end
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
  if #inside == 0 then
    return nil, errors.new("not_in_mux", "nvim does not run inside a supported multiplexer; cannot start a tool")
  end
  local term = vim.env.TERM_PROGRAM
  for _, backend in ipairs(inside) do
    if backend.name == term then
      return backend
    end
  end
  local names = vim.tbl_map(function(backend)
    return backend.name
  end, inside)
  return nil,
    errors.new(
      "not_in_mux",
      ("nvim runs inside several multiplexers (%s) and TERM_PROGRAM names none of them; cannot start a tool"):format(
        table.concat(names, ", ")
      )
    )
end

---Create a session of `tool` next to nvim through the selected backend, without focusing or attaching it.
---@param tool sidekick_ultra.Tool
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
function M.start(tool)
  local backend, err = M.start_backend()
  if not backend then
    return nil, err
  end
  return backend.start(tool, { cwd = vim.fn.getcwd(), env = vim.deepcopy(tool.env) })
end

return M
