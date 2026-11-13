---The tmux backend: sessions are tmux panes. Every command is `tmux [-S <socket>] <subcommand>`. The shapes were probed
---against tmux 3.8; what the live run must still settle is listed in tests/fixtures/tmux/UNVERIFIED.txt.
---
---tmux reports a pane's root process (`pane_pid`), not an agent, so a tool is found by walking that process's tree in
---nvim (`nvim_get_proc_children`, `nvim_get_proc`). On Unix Neovim answers those from its own fallback, which runs `ps`
---and `pgrep` itself (`vim._os_proc_info`, `vim._os_proc_children`). On top of that, a process whose name is a node or
---python interpreter costs one plugin `ps` call, to read the script it runs (see proc); no other argv and no environment
---is read.
---
---A pane is kept only when the matched process is its foreground program: the matched pid's kernel short name
---(`ps -o ucomm=`, one call per matched pane) must equal `#{pane_current_command}`, which tmux reports in the same
---form. A tool that is suspended or in the background, or runs inside another program's terminal, is not listed. `send`
---makes the same check again before it pastes, since an attached session outlives the tool's time in the foreground.
---`#{pane_current_command}` and `ucomm` were compared on macOS only; Linux is unverified.
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
  "#{pane_current_command}",
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

---@type string?
local socket

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

---@param args string[]
---@return string[] argv `tmux [-S socket] ...`
local function argv_of(args)
  local argv = { "tmux" }
  if socket then
    vim.list_extend(argv, { "-S", socket })
  end
  return vim.list_extend(argv, args)
end

---@param args string[]
---@param opts? sidekick_ultra.ExecOpts
---@return sidekick_ultra.ExecResult? result
---@return sidekick_ultra.ExecError? err
local function run(args, opts)
  return exec.check(argv_of(args), opts)
end

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
      local name, err = proc.tool_of(configured, pid, { proc_name })
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

---A session record. `tmux_session` is set for a listed pane only: a started pane is in nvim's own session, so `focus`
---never needs `switch-client` for it.
---@param tool_name string
---@param pane string
---@param cwd string
---@param pid integer
---@param proc_name string
---@param tmux_session? string
---@return sidekick_ultra.Session
local function session_of(tool_name, pane, cwd, pid, proc_name, tmux_session)
  return {
    id = M.name .. ":" .. pane,
    backend = M.name,
    tool = tool_name,
    cwd = cwd,
    pid = pid,
    proc_name = proc_name,
    pane = pane,
    tmux_session = tmux_session,
  }
end

---@param configured table<string, sidekick_ultra.Tool>
function M.list(configured)
  local res, err = run({ "list-panes", "-a", "-F", LIST_FORMAT })
  if not res then
    if no_server(err) then
      return {}
    end
    return nil, err
  end
  local ret, listed = {}, {}
  local own_pane = M.inside() and vim.env.TMUX_PANE or nil
  for _, row in ipairs(vim.split(res.stdout, "\n", { plain = true, trimempty = true })) do
    local f = vim.split(row, "\t", { plain = true })
    local root = tonumber(f[2])
    if #f < 6 or not f[1]:match("^%%%d+$") or not root then
      return nil, errors.new("backend_error", "tmux printed an unexpected pane list")
    end
    local cwd = table.concat(f, "\t", 6)
    -- A linked window lists its panes once per session that links it (seen live); the first row wins.
    local again = listed[f[1]]
    listed[f[1]] = true
    -- nvim's own pane is never a session; it is skipped before its tree is walked.
    if f[4] ~= "1" and not again and f[1] ~= own_pane then
      local name, pid, proc_name, find_err = find_tool(root, configured)
      if find_err then
        return nil, find_err
      end
      if name then
        local ucomm, ucomm_err = proc.ucomm(pid)
        if ucomm_err then
          return nil, ucomm_err
        end
        -- A vanished pid (nil ucomm) or a tool that is not the foreground program is no session.
        if ucomm == f[5] then
          if cwd == "" then
            return nil, errors.new("backend_error", "tmux printed no working directory for pane " .. f[1])
          end
          table.insert(ret, session_of(name, f[1], cwd, pid, proc_name, f[3]))
        end
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

---The session record of the pane `start` just split, whose root process is `root`.
---@param tool sidekick_ultra.Tool
---@param opts sidekick_ultra.StartOpts
---@param pane string
---@param root integer
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
local function started_session(tool, opts, pane, root)
  local _, pid, proc_name, find_err = find_tool(root, { [tool.name] = tool })
  if find_err then
    return nil, find_err
  end
  if not pid then
    proc_name = proc.name(root)
    if not proc_name then
      return nil, errors.new("backend_error", ("pane %s is not visible to this nvim"):format(pane))
    end
    pid = root
  end
  return session_of(tool.name, pane, opts.cwd, pid, proc_name)
end

---Split a new pane to the right of nvim's own pane, without focus, running the tool.
---With several command words tmux runs them directly as argv; with one it goes through `sh -c`, so that word is
---shell-escaped.
---@param tool sidekick_ultra.Tool
---@param opts sidekick_ultra.StartOpts
function M.start(tool, opts)
  local args = { "split-window", "-h", "-d", "-t", vim.env.TMUX_PANE, "-c", opts.cwd }
  for _, pair in ipairs(exec.env_pairs(opts.env)) do
    vim.list_extend(args, { "-e", pair })
  end
  vim.list_extend(args, { "-P", "-F", START_FORMAT, "--" })
  if #tool.cmd == 1 then
    table.insert(args, shell_word(tool.cmd[1]))
  else
    vim.list_extend(args, tool.cmd)
  end
  local res, err = run(args)
  if not res then
    return nil, err
  end
  local pane, root = res.stdout:match("^(%%%d+)\t(%d+)\n?$")
  if not pane then
    return nil, errors.new("backend_error", "tmux printed no id for the new pane")
  end

  local session, session_err = started_session(tool, opts, pane, tonumber(root) --[[@as integer]])
  if session_err then
    session_err.msg = ("%s; pane %s was left open"):format(session_err.msg, pane)
  end
  return session, session_err
end

---One `display-message -p -t <pane> <format>`, trimmed. A pane that does not exist is answered with "not found", never
---with an empty string.
---@param pane string
---@param format string
---@return string? out the trimmed answer of `display-message -p`
---@return sidekick_ultra.Error? err
local function display(pane, format)
  local res, err = run({ "display-message", "-p", "-t", pane, format })
  if not res then
    return nil, err
  end
  local out = vim.trim(res.stdout)
  -- tmux 3.8 answers a pane that does not exist with exit 0 and no output (seen live), not with an error.
  if out == "" then
    return nil, errors.new("backend_error", ("tmux pane %s not found"):format(pane))
  end
  return out
end

---Leave any mode the pane is in (copy mode after a scroll-back). In a mode the pane takes keys and pastes for the mode,
---not for the program, so Enter would end copy mode and the text would not reach the tool. The man page does not say
---whether `copy-mode -q` is harmless on a pane in no mode, so the mode count is read first (`#{pane_in_mode}`) and
---`copy-mode -q`, which cancels every mode, runs only when it is above zero.
---@param pane string
---@return true? ok
---@return sidekick_ultra.Error? err
local function leave_mode(pane)
  local out, err = display(pane, "#{pane_in_mode}")
  if not out then
    return nil, err
  end
  local modes = tonumber(out)
  if not modes then
    return nil, errors.new("backend_error", ("tmux printed an unexpected mode count for pane %s: %s"):format(pane, out))
  end
  if modes > 0 then
    local _, quit_err = run({ "copy-mode", "-q", "-t", pane })
    if quit_err then
      return nil, quit_err
    end
  end
  return true
end

---The tool of an attached session may have been suspended or sent to the background since discovery; its pid still
---passes the registry's liveness check. Text pasted then would reach the shell, which runs it. So before a send the
---session's pid must still be the pane's foreground program (the rule `list` applies): one `display-message` and one
---`ps`.
---@param session sidekick_ultra.Session
---@return true? ok
---@return sidekick_ultra.Error? err
local function require_foreground(session)
  local command, err = display(session.pane, "#{pane_current_command}")
  if not command then
    return nil, err
  end
  local ucomm, ucomm_err = proc.ucomm(session.pid)
  if ucomm_err then
    return nil, ucomm_err
  end
  if not ucomm then
    return nil, errors.new("backend_error", ("tmux pane %s: the tool's process is gone"):format(session.pane))
  end
  if ucomm ~= command then
    return nil,
      errors.new(
        "backend_error",
        ("tmux pane %s: the tool is not the foreground program (pane runs %s, the tool is %s)"):format(
          session.pane,
          command,
          ucomm
        )
      )
  end
  return true
end

---Raw text through a named paste buffer: `-r` keeps LF as LF, so no Enter is sent, `-S` stops tmux from passing the
---buffer through vis(3) (the default since tmux 3.7, which would turn an ESC byte into the text `\033`), and `-d`
---deletes the buffer.
---@param session sidekick_ultra.Session
---@param text string
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.send(session, text)
  local foreground, foreground_err = require_foreground(session)
  if not foreground then
    return nil, foreground_err
  end
  local left, mode_err = leave_mode(session.pane)
  if not left then
    return nil, mode_err
  end
  buffer_count = buffer_count + 1
  local buffer = ("sku-%d-%d"):format(vim.uv.os_getpid(), buffer_count)
  local loaded, err = run({ "load-buffer", "-b", buffer, "-" }, { stdin = text })
  if not loaded then
    return nil, err
  end
  local pasted, paste_err = run({ "paste-buffer", "-b", buffer, "-d", "-r", "-S", "-t", session.pane })
  if not pasted then
    -- The paste failed, so `-d` never ran: do not leave the text in the server.
    run({ "delete-buffer", "-b", buffer })
    return nil, paste_err
  end
  return pasted
end

---No foreground check: an Enter alone into a shell runs nothing new (the text it would run was refused by `send`).
---@param session sidekick_ultra.Session
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.submit(session)
  local left, mode_err = leave_mode(session.pane)
  if not left then
    return nil, mode_err
  end
  return run({ "send-keys", "-t", session.pane, "Enter" })
end

---`select-window ; select-pane` is server-side and needs no client. When nvim runs inside tmux and the pane is in
---another session, `switch-client` moves the client too; nvim's own session name is one `display-message` call.
---@param session sidekick_ultra.Session
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.focus(session)
  local args = { "select-window", "-t", session.pane, ";", "select-pane", "-t", session.pane }
  if session.tmux_session and M.inside() then
    local res, err = run({ "display-message", "-p", "-t", vim.env.TMUX_PANE, "#{session_name}" })
    if not res then
      return nil, err
    end
    if res.stdout:gsub("\n$", "") ~= session.tmux_session then
      vim.list_extend(args, { ";", "switch-client", "-t", session.pane })
    end
  end
  return run(args)
end

return M
