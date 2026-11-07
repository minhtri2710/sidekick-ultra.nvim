---Process names, and which configured tool a program name or a process runs.
---
---A process's own words are tried in the order the backend gives them; the interpreter's own name is not one of
---them, as it says nothing about which tool runs. The script is tried last, and only when no other word matched.
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")
local procname = require("sidekick-ultra.procname")

local M = {}

---What a tool's `is_proc` is asked about; built only in `matches`.
---@class sidekick_ultra.ProcInfo
---@field pid? integer the process id; absent when the backend sees no pid
---@field cmd string one program name, never a path or a command line: the process's name, the basename of its argv0,
---   or for a node or python interpreter the name of the script it runs (see procname). An empty name is never tested.

---@param pid integer
---@return string? name as nvim reads it; nil when the process is not visible to this nvim
function M.name(pid)
  local ok, info = pcall(vim.api.nvim_get_proc, pid)
  if ok and type(info) == "table" and type(info.name) == "string" then
    return info.name
  end
end

---The one place a user's `is_proc` runs: a throw is a `backend_error` naming the tool, not an answer.
---@param tool sidekick_ultra.Tool
---@param pid? integer
---@param cmd string
---@return boolean? matched
---@return sidekick_ultra.Error? err
function M.matches(tool, pid, cmd)
  if cmd == "" then
    return false
  end
  local ok, answer = pcall(tool.is_proc, { pid = pid, cmd = cmd })
  if not ok then
    return nil, errors.new("backend_error", ("is_proc of tool %s failed: %s"):format(tool.name, tostring(answer)))
  end
  return answer == true
end

---The first tool, in name order, that one of `cmds` satisfies.
---@param configured table<string, sidekick_ultra.Tool>
---@param pid? integer
---@param cmds string[]
---@return string? tool_name
---@return sidekick_ultra.Error? err a failing `is_proc`
function M.find(configured, pid, cmds)
  local names = vim.tbl_keys(configured)
  table.sort(names)
  for _, name in ipairs(names) do
    for _, cmd in ipairs(cmds) do
      local matched, err = M.matches(configured[name], pid, cmd)
      if err then
        return nil, err
      end
      if matched then
        return name
      end
    end
  end
end

---The name of the script an interpreter process runs, from one `ps` call. The command line is parsed and dropped:
---a failing ps reports the pid, the exit code and the first stderr line, never stdout.
---`ps -p <pid>` for a pid that no longer exists exits 1 and prints nothing on either stream (seen on macOS; the macOS
---man page states no exit status for it). That is a process that ended after nvim read its name, which is ordinary for
---short-lived helpers: it is skipped. Any other failure, and exit 0 with nothing printed, is an error.
---@param pid integer
---@return string? script "" when the interpreter runs none; nil when the process is gone
---@return sidekick_ultra.Error? err
local function script_of(pid)
  local argv = { "ps", "-ww", "-o", "args=", "-p", tostring(pid) }
  local res, err = exec.run(argv)
  if not res then
    return nil, err
  end
  if res.code == 1 and res.stdout == "" and res.stderr == "" then
    return nil
  end
  if res.code ~= 0 then
    return nil, exec.result_error(argv, res, ("ps exited with %d for pid %d"):format(res.code, pid))
  end
  local script = procname.program(res.stdout)
  if not script then
    return nil, exec.result_error(argv, res, ("ps printed nothing for pid %d"):format(pid))
  end
  return script
end

---The configured tool that process `pid`, known by `words`, runs.
---@param configured table<string, sidekick_ultra.Tool>
---@param pid integer
---@param words string[] names of the process, most telling first
---@return string? tool_name
---@return sidekick_ultra.Error? err a failing ps or `is_proc`
function M.tool_of(configured, pid, words)
  if next(configured) == nil then
    return nil
  end
  local cmds, interpreter = {}, false
  for _, word in ipairs(words) do
    if procname.is_interpreter(word) then
      interpreter = true
    else
      table.insert(cmds, word)
    end
  end
  local name, err = M.find(configured, pid, cmds)
  if name or err or not interpreter then
    return name, err
  end
  local script, script_err = script_of(pid)
  if not script then
    return nil, script_err
  end
  return M.find(configured, pid, { script })
end

return M
