---The tmux backend: sessions are tmux panes. Every command is `tmux [-S <socket>] <subcommand>`, run through the exec
---seam. The shapes were probed against tmux 3.8 in D8 (design.md section 11); what the live run must still settle is
---listed in tests/fixtures/tmux/UNVERIFIED.txt.
---
---tmux reports a pane's root process (`pane_pid`), not an agent, so a tool is found by walking that process's tree in
---nvim (`nvim_get_proc_children`, `nvim_get_proc`). Only a process whose name is a node or python interpreter costs a
---`ps` call, to read the script it runs (see proc); no other argv and no environment is read. tmux has no agent
---status, so `send` has no blocked guard.
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")
local proc = require("sidekick-ultra.proc")

---@type sidekick_ultra.Backend
local M = { name = "tmux" }

---Fields of the `list-panes` rows, tab separated (the separator is a real tab: tmux passes it through). The working
---directory comes last, so a path that holds a tab stays whole; it is the pane's current path, or the path the pane
---was started in when tmux cannot read the current one.
local LIST_FORMAT = table.concat({
  "#{pane_id}",
  "#{pane_pid}",
  "#{session_name}",
  "#{pane_dead}",
  "#{?pane_current_path,#{pane_current_path},#{pane_start_path}}",
}, "\t")
local START_FORMAT = "#{pane_id}\t#{pane_pid}"

---Stderr first lines tmux prints when no server answers: ECONNREFUSED and a missing socket.
local NO_SERVER = { "^no server running", "^error connecting to .* %(No such file or directory%)$" }

---@param err sidekick_ultra.ExecError
---@return boolean
local function no_server(err)
  for _, pattern in ipairs(NO_SERVER) do
    if (err.stderr or ""):find(pattern) then
      return true
    end
  end
  return false
end

local buffer_count = 0

---`tmux.socket` from the last `setup()`.
---@type string?
local socket

---Replace the options.
---@param opts { socket?: string }
function M.setup(opts)
  socket = opts.socket
end

---@return boolean ok
---@return string? path
---@return string? source
function M.available()
  return exec.on_path("tmux")
end

---@param a string
---@param b string
---@return boolean
local function same_path(a, b)
  a, b = vim.fs.normalize(a), vim.fs.normalize(b)
  if a == b then
    return true
  end
  local real_a, real_b = vim.uv.fs_realpath(a), vim.uv.fs_realpath(b)
  return real_a ~= nil and real_a == real_b
end

---nvim's own pane is `$TMUX_PANE`, in the server `$TMUX` names (its first comma-separated field is the socket path).
---With `tmux.socket` set, every call goes to that socket, so nvim counts as inside only when its own server is that
---socket; otherwise `$TMUX_PANE` would name a pane of another server.
function M.inside()
  local env = vim.env.TMUX or ""
  if env == "" or (vim.env.TMUX_PANE or "") == "" then
    return false
  end
  return socket == nil or same_path(env:match("^[^,]*"), socket)
end

---@param label string
---@param msg string
---@return sidekick_ultra.Error
local function failure(label, msg)
  return errors.new("backend_error", msg, { backend = M.name, cmd = label })
end

---@param args string[]
---@return string[] argv `tmux [-S socket] ...`
local function argv_of(args)
  local argv = { "tmux" }
  if socket then
    vim.list_extend(argv, { "-S", socket })
  end
  return vim.list_extend(argv, args)
end

---@param label string subcommand label for errors
---@param args string[]
---@param opts? sidekick_ultra.ExecOpts
---@return sidekick_ultra.ExecResult? result
---@return sidekick_ultra.ExecError? err
local function run(label, args, opts)
  return exec.check(argv_of(args), vim.tbl_extend("force", opts or {}, { backend = M.name, cmd = label }))
end

---Breadth-first over the process tree under `root` (root first): the first process whose name, or script name for an
---interpreter, satisfies a tool.
---@param root integer
---@param configured table<string, sidekick_ultra.Tool>
---@return string? tool_name
---@return integer? pid
---@return string? proc_name the process name nvim reads (the interpreter's, for a script)
---@return sidekick_ultra.Error? err a failing ps
local function find_tool(root, configured)
  local queue, seen, i = { root }, { [root] = true }, 1
  while queue[i] do
    local pid = queue[i]
    i = i + 1
    local proc_name = proc.name(pid)
    if proc_name then
      local name, err = proc.tool_of(M.name, configured, pid, { proc_name })
      if err then
        return nil, nil, nil, err
      end
      if name then
        return name, pid, proc_name
      end
    end
    local has_kids, kids = pcall(vim.api.nvim_get_proc_children, pid)
    for _, kid in ipairs(has_kids and type(kids) == "table" and kids or {}) do
      if not seen[kid] then
        seen[kid] = true
        table.insert(queue, kid)
      end
    end
  end
end

---@param configured table<string, sidekick_ultra.Tool>
function M.list(configured)
  local res, err = run("list-panes", { "list-panes", "-a", "-F", LIST_FORMAT })
  if not res then
    if no_server(err) then
      return {}
    end
    return nil, err
  end
  local ret = {}
  for _, row in ipairs(vim.split(res.stdout, "\n", { plain = true, trimempty = true })) do
    local f = vim.split(row, "\t", { plain = true })
    local root = tonumber(f[2])
    if #f < 5 or not f[1]:match("^%%%d+$") or not root then
      return nil, failure("list-panes", "tmux printed an unexpected pane list")
    end
    local cwd = table.concat(f, "\t", 5)
    if f[4] ~= "1" then
      local name, pid, proc_name, find_err = find_tool(root, configured)
      if find_err then
        return nil, find_err
      end
      if name then
        if cwd == "" then
          return nil, failure("list-panes", "tmux printed no working directory for pane " .. f[1])
        end
        table.insert(ret, {
          id = "tmux:" .. f[1],
          backend = M.name,
          tool = name,
          cwd = cwd,
          pid = pid,
          proc_name = proc_name,
          pane = f[1],
          tmux_session = f[3],
        })
      end
    end
  end
  return ret
end

---One shell word, for the single-element command tmux runs through `sh -c`.
---@param word string
---@return string
local function shell_word(word)
  return "'" .. word:gsub("'", "'\\''") .. "'"
end

---Split a new pane to the right of nvim's own pane, without focus, running the tool.
---With several command words tmux runs them directly as argv; with one it goes through `sh -c`, so that word is
---shell-escaped.
---@param tool sidekick_ultra.Tool
---@param opts sidekick_ultra.StartOpts
function M.start(tool, opts)
  local args = { "split-window", "-h", "-d", "-t", vim.env.TMUX_PANE, "-c", opts.cwd }
  local keys = vim.tbl_keys(opts.env)
  table.sort(keys)
  for _, key in ipairs(keys) do
    vim.list_extend(args, { "-e", key .. "=" .. opts.env[key] })
  end
  vim.list_extend(args, { "-P", "-F", START_FORMAT, "--" })
  if #tool.cmd == 1 then
    table.insert(args, shell_word(tool.cmd[1]))
  else
    vim.list_extend(args, tool.cmd)
  end
  local res, err = run("split-window", args)
  if not res then
    return nil, err
  end
  local pane, root = res.stdout:match("^(%%%d+)\t(%d+)\n?$")
  if not pane then
    return nil, failure("split-window", "tmux printed no id for the new pane")
  end
  root = tonumber(root) --[[@as integer]]

  -- The pane is "running" at once: record the tool's process if it is already up, else the pane's root process (the
  -- shell or the command). The next discovery replaces this record with the tool's own pid, matched by id.
  local _, pid, proc_name, find_err = find_tool(root, { [tool.name] = tool })
  if find_err then
    return nil, failure("split-window", ("%s; pane %s was left open"):format(find_err.msg, pane))
  end
  if not pid then
    proc_name = proc.name(root)
    if not proc_name then
      return nil, failure("split-window", ("pane %s is not visible to this nvim; it was left open"):format(pane))
    end
    pid = root
  end
  -- No tmux_session: the pane is in nvim's own session, so `focus` never needs switch-client for it.
  return {
    id = "tmux:" .. pane,
    backend = M.name,
    tool = tool.name,
    cwd = opts.cwd,
    pid = pid,
    proc_name = proc_name,
    pane = pane,
  }
end

---Leave any mode the pane is in (copy mode after a scroll-back). In a mode the pane takes keys and pastes for the mode,
---not for the program, so Enter would end copy mode and the text would not reach the tool. The man page does not say
---whether `copy-mode -q` is harmless on a pane in no mode, so the mode count is read first (`#{pane_in_mode}`) and
---`copy-mode -q`, which cancels every mode, runs only when it is above zero.
---@param pane string
---@return true? ok
---@return sidekick_ultra.Error? err
local function leave_mode(pane)
  local res, err = run("display-message", { "display-message", "-p", "-t", pane, "#{pane_in_mode}" })
  if not res then
    return nil, err
  end
  local out = vim.trim(res.stdout)
  -- tmux 3.8 answers a pane that does not exist with exit 0 and no output (seen live), not with an error.
  if out == "" then
    return nil, failure("display-message", ("tmux pane %s not found"):format(pane))
  end
  local modes = tonumber(out)
  if not modes then
    return nil, failure("display-message", ("tmux printed an unexpected mode count for pane %s: %s"):format(pane, out))
  end
  if modes > 0 then
    local _, quit_err = run("copy-mode", { "copy-mode", "-q", "-t", pane })
    if quit_err then
      return nil, quit_err
    end
  end
  return true
end

---Raw text through a named paste buffer: `-r` keeps LF as LF, so no Enter is sent, `-S` stops tmux from passing the
---buffer through vis(3) (the default since tmux 3.7, which would turn an ESC byte into the text `\033`), and `-d`
---deletes the buffer.
---@param session sidekick_ultra.Session
---@param text string
function M.send(session, text)
  local left, mode_err = leave_mode(session.pane)
  if not left then
    return nil, mode_err
  end
  buffer_count = buffer_count + 1
  local buffer = ("sku-%d-%d"):format(vim.uv.os_getpid(), buffer_count)
  local loaded, err = run("load-buffer", { "load-buffer", "-b", buffer, "-" }, { stdin = text })
  if not loaded then
    return nil, err
  end
  local pasted, paste_err = run("paste-buffer", { "paste-buffer", "-b", buffer, "-d", "-r", "-S", "-t", session.pane })
  if not pasted then
    -- The paste failed, so `-d` never ran: do not leave the text in the server.
    run("delete-buffer", { "delete-buffer", "-b", buffer })
    return nil, paste_err
  end
  return true
end

---@param session sidekick_ultra.Session
function M.submit(session)
  local left, mode_err = leave_mode(session.pane)
  if not left then
    return nil, mode_err
  end
  local res, err = run("send-keys", { "send-keys", "-t", session.pane, "Enter" })
  return res and true or nil, err
end

---`select-window ; select-pane` is server-side and needs no client. When nvim runs inside tmux and the pane is in
---another session, `switch-client` moves the client too; nvim's own session name is one `display-message` call.
---@param session sidekick_ultra.Session
function M.focus(session)
  local args = { "select-window", "-t", session.pane, ";", "select-pane", "-t", session.pane }
  if session.tmux_session and M.inside() then
    local res, err = run("display-message", { "display-message", "-p", "-t", vim.env.TMUX_PANE, "#{session_name}" })
    if not res then
      return nil, err
    end
    if res.stdout:gsub("\n$", "") ~= session.tmux_session then
      vim.list_extend(args, { ";", "switch-client", "-t", session.pane })
    end
  end
  local res, err = run("select-window", args)
  return res and true or nil, err
end

return M
