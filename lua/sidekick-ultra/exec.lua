---The only place that runs external commands. Tests replace `run`; everything else calls it through this table.
local errors = require("sidekick-ultra.errors")

local M = {}

M.DEFAULT_TIMEOUT_MS = 5000

---@class sidekick_ultra.ExecOpts
---@field stdin? string
---@field timeout_ms? integer
---@field env? table<string, string> extra variables added to the inherited environment

---The `backend_error` of a command that ran and failed: `code` is its exit code and `stderr` the first line of its
---stderr, so a caller can classify the failure. A spawn failure, a timeout and invalid output carry neither `stderr`
---nor a failing exit code. `empty` is set by `json` when the command exited 0 and printed nothing.
---@class sidekick_ultra.ExecError: sidekick_ultra.Error
---@field stderr? string
---@field empty? true

---@class sidekick_ultra.ExecResult
---@field code integer
---@field stdout string
---@field stderr string

---@param msg string
---@param code? integer
---@return sidekick_ultra.ExecError
local function failure(msg, code)
  return errors.new("backend_error", msg, { code = code })
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
    env = opts.env,
  })
  if not ok then
    return nil, failure(("cannot run %s: %s"):format(tostring(argv[1]), tostring(proc)))
  end
  local res = proc:wait()
  -- vim.system reports a timeout as exit 124 after killing the process: SIGTERM, or SIGKILL when it ignores that.
  -- After SIGKILL it can return nil when a child keeps the pipes open: that is the timeout too.
  if res == nil or (res.code == 124 and res.signal ~= 0) then
    return nil, failure(("%s timed out after %d ms"):format(argv[1], timeout))
  end
  return { code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" }
end

---The error for a result a caller found to be a failure: `head` (default `<bin> exited with <code>`), then the first
---stderr line. For a caller that must read stdout before it decides, as `run` leaves a non-zero exit to the caller.
---@param argv string[]
---@param res sidekick_ultra.ExecResult
---@param head? string
---@return sidekick_ultra.ExecError
function M.result_error(argv, res, head)
  local first = vim.split(res.stderr, "\n", { plain = true })[1]
  head = head or ("%s exited with %d"):format(argv[1], res.code)
  local err = failure(first ~= "" and (head .. ": " .. first) or head, res.code)
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
    return nil, M.result_error(argv, res)
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

---`check`, with stdout decoded as JSON. Empty or invalid output is a `backend_error`; empty output also sets `empty`,
---for a caller that asks again.
---@param argv string[]
---@param opts? sidekick_ultra.ExecOpts
---@return any? decoded
---@return sidekick_ultra.ExecError? err
function M.json(argv, opts)
  local res, err = M.check(argv, opts)
  if not res then
    return nil, err
  end
  local ok, decoded = M.decode(res.stdout)
  if not ok then
    local invalid = failure(("%s printed invalid JSON"):format(argv[1]), res.code)
    invalid.empty = vim.trim(res.stdout) == "" or nil
    return nil, invalid
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

---The `K=V` words of `vars`, keys sorted.
---@param vars table<string, string>
---@return string[]
function M.env_pairs(vars)
  local keys = vim.tbl_keys(vars)
  table.sort(keys)
  return vim.tbl_map(function(key)
    return key .. "=" .. vars[key]
  end, keys)
end

---The words that put `vars` in front of a command: `/usr/bin/env K=V ...`, nothing when `vars` is empty. For a CLI that
---has no environment flag.
---@param vars table<string, string>
---@return string[]
function M.env_prefix(vars)
  local words = M.env_pairs(vars)
  if #words == 0 then
    return {}
  end
  return vim.list_extend({ "/usr/bin/env" }, words)
end

return M
