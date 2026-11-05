---Fake backends and session records for specs. Nothing here runs an external command.
local M = {}

---Name of this nvim process as `nvim_get_proc` reports it, so a session recorded with it counts as running.
function M.self_proc()
  local pid = vim.uv.os_getpid()
  return pid, vim.api.nvim_get_proc(pid).name
end

---@param backend string
---@param tool string
---@param n? integer|string
---@param extra? table
---@return sidekick_ultra.Session
function M.session(backend, tool, n, extra)
  local pid, name = M.self_proc()
  return vim.tbl_extend("force", {
    id = ("%s:%s%s"):format(backend, tool, n or 1),
    backend = backend,
    tool = tool,
    cwd = vim.fn.getcwd(),
    pid = pid,
    proc_name = name,
    state = "idle",
  }, extra or {})
end

---A recording backend. Fields to steer it: `sessions`, `is_inside`, `list_err`, `start_err`, `fail` (method name ->
---error, or a function(call_count) returning an error or nil). `calls` records every call as `{method, ...}`;
---`delivered` holds the text of every send that succeeded.
---@param name string
---@param opts? table
---@return table backend
function M.backend(name, opts)
  local b = vim.tbl_extend("force", { sessions = {}, is_inside = false, fail = {} }, opts or {})
  b.name = name
  b.calls = {}
  b.delivered = {}
  b.counts = {}

  local function failure(method)
    b.counts[method] = (b.counts[method] or 0) + 1
    local spec = b.fail[method]
    if type(spec) == "function" then
      return spec(b.counts[method])
    end
    return spec
  end

  function b.available()
    return true, "/fake/" .. name, "fake"
  end
  function b.inside()
    return b.is_inside
  end
  function b.list(tools)
    table.insert(b.calls, { "list", vim.tbl_keys(tools) })
    if b.list_err then
      return nil, b.list_err
    end
    return vim.deepcopy(b.sessions)
  end
  function b.start(tool, o)
    table.insert(b.calls, { "start", tool.name, o })
    if b.start_err then
      return nil, b.start_err
    end
    b.started = (b.started or 0) + 1
    return M.session(name, tool.name, "new" .. b.started, { cwd = o.cwd })
  end
  function b.send(session, text)
    table.insert(b.calls, { "send", session.id, text })
    local err = failure("send")
    if err then
      return nil, err
    end
    table.insert(b.delivered, text)
    return true
  end
  function b.submit(session)
    table.insert(b.calls, { "submit", session.id })
    local err = failure("submit")
    if err then
      return nil, err
    end
    return true
  end
  function b.focus(session)
    table.insert(b.calls, { "focus", session.id })
    local err = failure("focus")
    if err then
      return nil, err
    end
    return true
  end
  ---@param method string
  ---@return table[]
  function b.of(method)
    return vim.tbl_filter(function(call)
      return call[1] == method
    end, b.calls)
  end
  return b
end

---Reset every module the specs touch to a clean state: every real backend disabled and no built-in tools, so the
---result does not depend on what is installed. `tools` adds the tools a spec needs (config entries).
---@param tools? table<string, table>
---@param extra? table more setup options
function M.reset(tools, extra)
  local cfg = {
    herdr = { enabled = false },
    rex = { enabled = false },
    tmux = { enabled = false },
    zellij = { enabled = false },
    tools = {},
  }
  for _, name in ipairs(require("sidekick-ultra.tools").builtin_names()) do
    cfg.tools[name] = false
  end
  for name, spec in pairs(tools or {}) do
    cfg.tools[name] = spec
  end
  require("sidekick-ultra").setup(vim.tbl_extend("force", cfg, extra or {}))
  require("sidekick-ultra.status").reset()
end

---An executable that makes a tool count as installed.
M.INSTALLED = { "/bin/sh" }

return M
