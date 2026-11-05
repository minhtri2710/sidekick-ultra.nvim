---The only place that runs external commands. Tests replace `run`; everything else calls it through this table.
local errors = require("sidekick-ultra.errors")

local M = {}

M.DEFAULT_TIMEOUT_MS = 5000

---@class sidekick_ultra.ExecOpts
---@field stdin? string
---@field timeout_ms? integer
---@field env? table<string, string> extra variables added to the inherited environment
---@field cwd? string
---@field backend? string backend name used in a `backend_error`
---@field cmd? string subcommand label used in a `backend_error` (default: argv[2])

---@class sidekick_ultra.ExecResult
---@field code integer
---@field stdout string
---@field stderr string

---@param opts? sidekick_ultra.ExecOpts
---@param argv string[]
---@param msg string
---@param code? integer
---@return sidekick_ultra.Error
local function failure(opts, argv, msg, code)
  opts = opts or {}
  return errors.new("backend_error", msg, {
    backend = opts.backend,
    cmd = opts.cmd or argv[2] or argv[1],
    code = code,
  })
end

---Run `argv` synchronously. A spawn failure or a timeout is a `backend_error`; a non-zero exit is not
---(see `check`).
---@param argv string[]
---@param opts? sidekick_ultra.ExecOpts
---@return sidekick_ultra.ExecResult? result
---@return sidekick_ultra.Error? err
function M.run(argv, opts)
  opts = opts or {}
  local timeout = opts.timeout_ms or M.DEFAULT_TIMEOUT_MS
  local ok, proc = pcall(vim.system, argv, {
    text = true,
    stdin = opts.stdin,
    timeout = timeout,
    cwd = opts.cwd,
    env = opts.env,
  })
  if not ok then
    return nil, failure(opts, argv, ("cannot run %s: %s"):format(tostring(argv[1]), tostring(proc)))
  end
  local res = proc:wait()
  -- vim.system reports a timeout as exit 124 after killing the process with SIGTERM.
  if res.code == 124 and res.signal == 15 then
    return nil, failure(opts, argv, ("%s timed out after %d ms"):format(argv[1], timeout))
  end
  return { code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" }
end

---`run`, with a non-zero exit mapped to `backend_error` (exit code and first stderr line).
---@param argv string[]
---@param opts? sidekick_ultra.ExecOpts
---@return sidekick_ultra.ExecResult? result
---@return sidekick_ultra.Error? err
function M.check(argv, opts)
  local res, err = M.run(argv, opts)
  if not res then
    return nil, err
  end
  if res.code ~= 0 then
    local first = vim.split(res.stderr, "\n", { plain = true })[1]
    local msg = ("%s exited with %d"):format(argv[1], res.code)
    return nil, failure(opts, argv, first ~= "" and (msg .. ": " .. first) or msg, res.code)
  end
  return res
end

---`check`, with stdout decoded as JSON. Empty or invalid output is a `backend_error`.
---@param argv string[]
---@param opts? sidekick_ultra.ExecOpts
---@return any? decoded
---@return sidekick_ultra.Error? err
function M.json(argv, opts)
  local res, err = M.check(argv, opts)
  if not res then
    return nil, err
  end
  local ok, decoded = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
  if not ok then
    return nil, failure(opts, argv, ("%s printed invalid JSON"):format(argv[1]), res.code)
  end
  return decoded
end

return M
