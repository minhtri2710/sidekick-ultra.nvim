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
---@field cmd? string subcommand label used in a `backend_error`

---The `backend_error` of a command that ran and failed: `code` is its exit code and `stderr` the first line of its
---stderr, so a caller can classify the failure. A spawn failure, a timeout and invalid output carry neither `stderr`
---nor a failing exit code.
---@class sidekick_ultra.ExecError: sidekick_ultra.Error
---@field stderr? string

---@class sidekick_ultra.ExecResult
---@field code integer
---@field stdout string
---@field stderr string

---@param opts? sidekick_ultra.ExecOpts
---@param msg string
---@param code? integer
---@return sidekick_ultra.Error
local function failure(opts, msg, code)
  opts = opts or {}
  return errors.new("backend_error", msg, { backend = opts.backend, cmd = opts.cmd, code = code })
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
    return nil, failure(opts, ("cannot run %s: %s"):format(tostring(argv[1]), tostring(proc)))
  end
  local res = proc:wait()
  -- vim.system reports a timeout as exit 124 after killing the process: SIGTERM, or SIGKILL when it ignores that.
  if res.code == 124 and res.signal ~= 0 then
    return nil, failure(opts, ("%s timed out after %d ms"):format(argv[1], timeout))
  end
  return { code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" }
end

---The error for a result a caller found to be a failure: `head` (default `<bin> exited with <code>`), then the first
---stderr line. For a caller that must read stdout before it decides, as `run` leaves a non-zero exit to the caller.
---@param argv string[]
---@param res sidekick_ultra.ExecResult
---@param opts? sidekick_ultra.ExecOpts
---@param head? string
---@return sidekick_ultra.ExecError
function M.result_error(argv, res, opts, head)
  local first = vim.split(res.stderr, "\n", { plain = true })[1]
  head = head or ("%s exited with %d"):format(argv[1], res.code)
  local err = failure(opts, first ~= "" and (head .. ": " .. first) or head, res.code)
  err.stderr = first
  return err
end

---`run`, with a non-zero exit mapped to an `ExecError`.
---@param argv string[]
---@param opts? sidekick_ultra.ExecOpts
---@return sidekick_ultra.ExecResult? result
---@return sidekick_ultra.ExecError? err
function M.check(argv, opts)
  local res, err = M.run(argv, opts)
  if not res then
    return nil, err
  end
  if res.code ~= 0 then
    return nil, M.result_error(argv, res, opts)
  end
  return res
end

---Decode JSON text, turning null into nil.
---@param text string
---@return boolean ok
---@return any? decoded
function M.decode(text)
  return pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
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
  local ok, decoded = M.decode(res.stdout)
  if not ok then
    return nil, failure(opts, ("%s printed invalid JSON"):format(argv[1]), res.code)
  end
  return decoded
end

---Where `bin` is found on PATH, in the shape of a backend's `available`.
---@param bin string
---@return boolean ok
---@return string? path
---@return string? source "PATH"
function M.on_path(bin)
  local path = vim.fn.exepath(bin)
  if path == "" then
    return false
  end
  return true, path, "PATH"
end

---The words that put `env` in front of a command: `/usr/bin/env K=V ...`, keys sorted, nothing for an empty `env`.
---For a CLI that has no environment flag.
---@param env table<string, string>
---@return string[]
function M.env_prefix(env)
  local keys = vim.tbl_keys(env)
  if #keys == 0 then
    return {}
  end
  table.sort(keys)
  local words = { "/usr/bin/env" }
  for _, key in ipairs(keys) do
    table.insert(words, key .. "=" .. env[key])
  end
  return words
end

return M
