---Which configured tool a process runs, for the backends that see processes (rex, tmux, zellij). herdr names the
---agent itself and does not come here.
---
---Every `is_proc` is called with one `sidekick_ultra.ProcInfo`, built only in `matches`: `{ pid?, cmd }`.
---  pid  the process id. Absent only for zellij, which reports none (0.45.1).
---  cmd  one program name, never a path or a command line: the process's name, the basename of its argv0, or for a
---       node or python interpreter the name of the script it runs (see procname). An empty name is never tested.
---A process's own words are tried in the order the backend gives them; the interpreter's own name is not one of
---them, as it says nothing about which tool runs. The script is tried last, and only when no other word matched.
local exec = require("sidekick-ultra.exec")
local procname = require("sidekick-ultra.procname")
local tools = require("sidekick-ultra.tools")

local M = {}

---@param pid integer
---@return string? name as nvim reads it; nil when the process is not visible to this nvim
function M.name(pid)
  local ok, info = pcall(vim.api.nvim_get_proc, pid)
  if ok and type(info) == "table" and type(info.name) == "string" then
    return info.name
  end
end

---@param tool sidekick_ultra.Tool
---@param pid? integer
---@param cmd string
---@return boolean
function M.matches(tool, pid, cmd)
  return cmd ~= "" and tools.matches(tool, { pid = pid, cmd = cmd })
end

---The first tool, in name order, that one of `cmds` satisfies.
---@param configured table<string, sidekick_ultra.Tool>
---@param pid? integer
---@param cmds string[]
---@return string? tool_name
function M.find(configured, pid, cmds)
  local names = vim.tbl_keys(configured)
  table.sort(names)
  for _, name in ipairs(names) do
    for _, cmd in ipairs(cmds) do
      if M.matches(configured[name], pid, cmd) then
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
---@param backend string the backend named in an error
---@param pid integer
---@return string? script "" when the interpreter runs none; nil when the process is gone
---@return sidekick_ultra.Error? err
local function script_of(backend, pid)
  local argv = { "ps", "-ww", "-o", "args=", "-p", tostring(pid) }
  local opts = { backend = backend, cmd = "ps" }
  local res, err = exec.run(argv, opts)
  if not res then
    return nil, err
  end
  if res.code == 1 and res.stdout == "" and res.stderr == "" then
    return nil
  end
  if res.code ~= 0 then
    return nil, exec.result_error(argv, res, opts, ("ps exited with %d for pid %d"):format(res.code, pid))
  end
  local script = procname.program(res.stdout)
  if not script then
    return nil, exec.result_error(argv, res, opts, ("ps printed nothing for pid %d"):format(pid))
  end
  return script
end

---The configured tool that process `pid`, known by `words`, runs. A node or python interpreter among the words costs
---one `ps` call, unless a word already matched or no tool is configured.
---@param backend string the backend named in an error
---@param configured table<string, sidekick_ultra.Tool>
---@param pid integer
---@param words string[] names of the process, most telling first
---@return string? tool_name
---@return sidekick_ultra.Error? err a failing ps
function M.tool_of(backend, configured, pid, words)
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
  local name = M.find(configured, pid, cmds)
  if name or not interpreter then
    return name
  end
  local script, err = script_of(backend, pid)
  if not script then
    return nil, err
  end
  return M.find(configured, pid, { script })
end

return M
