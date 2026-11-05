---The tmux backend: sessions are tmux panes. Every command is `tmux [-S <socket>] <subcommand>`, run through the exec
---seam. The shapes were probed against tmux 3.8 in D8 (design.md section 11); what the live run must still settle is
---listed in tests/fixtures/tmux/UNVERIFIED.txt.
---
---tmux reports a pane's root process (`pane_pid`), not an agent, so a tool is found by walking that process's tree in
---nvim (`nvim_get_proc_children`, `nvim_get_proc`). No `ps`, and no argv or environment is read. tmux has no agent
---status, so `send` has no blocked guard.
local config = require("sidekick-ultra.config")
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")
local tools = require("sidekick-ultra.tools")

---@type sidekick_ultra.Backend
local M = { name = "tmux" }

---Fields of the `list-panes` rows, tab separated (the separator is a real tab: tmux passes it through).
local LIST_FORMAT = table.concat({
  "#{pane_id}",
  "#{pane_pid}",
  "#{pane_current_path}",
  "#{session_name}",
  "#{window_id}",
  "#{pane_dead}",
}, "\t")
local START_FORMAT = "#{pane_id}\t#{pane_pid}"

---Stderr first lines tmux prints when no server answers: ECONNREFUSED and a missing socket.
local NO_SERVER = { "^no server running", "^error connecting to .* %(No such file or directory%)$" }

local buffer_count = 0

---@return boolean ok
---@return string? path
---@return string? source
function M.available()
  local path = vim.fn.exepath("tmux")
  if path == "" then
    return false
  end
  return true, path, "PATH"
end

---True when `a` and `b` name the same file: equal after normalizing, or equal real paths when both resolve.
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
  local socket = config.get().tmux.socket
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
  local socket = config.get().tmux.socket
  if socket then
    vim.list_extend(argv, { "-S", socket })
  end
  return vim.list_extend(argv, args)
end

---Run a tmux command; a failure is a `backend_error` with the first stderr line.
---@param label string subcommand label for errors
---@param args string[]
---@param opts? sidekick_ultra.ExecOpts
---@return sidekick_ultra.ExecResult? result
---@return sidekick_ultra.Error? err
local function run(label, args, opts)
  return exec.check(argv_of(args), vim.tbl_extend("force", opts or {}, { backend = M.name, cmd = label }))
end

---Breadth-first over the process tree under `root` (root first): the first process whose name satisfies a tool.
---@param root integer
---@param configured table<string, sidekick_ultra.Tool>
---@return string? tool_name
---@return integer? pid
---@return string? proc_name
local function find_tool(root, configured)
  local names = vim.tbl_keys(configured)
  table.sort(names)
  local queue, seen, i = { root }, { [root] = true }, 1
  while queue[i] do
    local pid = queue[i]
    i = i + 1
    local ok, info = pcall(vim.api.nvim_get_proc, pid)
    if ok and type(info) == "table" and type(info.name) == "string" then
      for _, name in ipairs(names) do
        if tools.matches(configured[name], { pid = pid, cmd = info.name }) then
          return name, pid, info.name
        end
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
  local res, err =
    exec.run(argv_of({ "list-panes", "-a", "-F", LIST_FORMAT }), { backend = M.name, cmd = "list-panes" })
  if not res then
    return nil, err
  end
  if res.code ~= 0 then
    local first = vim.split(res.stderr, "\n", { plain = true })[1]
    -- No server is no sessions, not a failure worth a toast on every discovery.
    for _, pattern in ipairs(NO_SERVER) do
      if first:find(pattern) then
        return {}
      end
    end
    local msg = ("tmux exited with %d: %s"):format(res.code, first)
    return nil, errors.new("backend_error", msg, { backend = M.name, cmd = "list-panes", code = res.code })
  end
  local ret = {}
  for _, row in ipairs(vim.split(res.stdout, "\n", { plain = true, trimempty = true })) do
    local f = vim.split(row, "\t", { plain = true })
    local root = tonumber(f[2])
    if #f ~= 6 or not f[1]:match("^%%%d+$") or not root then
      return nil, failure("list-panes", "tmux printed an unexpected pane list")
    end
    if f[6] ~= "1" then
      local name, pid, proc_name = find_tool(root, configured)
      if name then
        if f[3] == "" then
          return nil, failure("list-panes", "tmux printed no working directory for pane " .. f[1])
        end
        table.insert(ret, {
          id = "tmux:" .. f[1],
          backend = M.name,
          tool = name,
          cwd = f[3],
          pid = pid,
          proc_name = proc_name,
          pane = f[1],
          tmux_session = f[4],
          window_id = f[5],
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
---shell-escaped. The tool's `env` goes in as `-e K=V`.
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
  local _, pid, proc_name = find_tool(root, { [tool.name] = tool })
  if not pid then
    local ok, info = pcall(vim.api.nvim_get_proc, root)
    if not ok or type(info) ~= "table" or type(info.name) ~= "string" then
      return nil, failure("split-window", ("pane %s is not visible to this nvim; it was left open"):format(pane))
    end
    pid, proc_name = root, info.name
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

---Raw text through a named paste buffer: `-r` keeps LF as LF, so no Enter is sent, and `-d` deletes the buffer.
---@param session sidekick_ultra.Session
---@param text string
function M.send(session, text)
  if text == "" then
    return true
  end
  buffer_count = buffer_count + 1
  local buffer = ("sku-%d-%d"):format(vim.uv.os_getpid(), buffer_count)
  local loaded, err = run("load-buffer", { "load-buffer", "-b", buffer, "-" }, { stdin = text })
  if not loaded then
    return nil, err
  end
  local pasted, paste_err = run("paste-buffer", { "paste-buffer", "-b", buffer, "-d", "-r", "-t", session.pane })
  if not pasted then
    -- The paste failed, so `-d` never ran: do not leave the text in the server.
    run("delete-buffer", { "delete-buffer", "-b", buffer })
    return nil, paste_err
  end
  return true
end

---@param session sidekick_ultra.Session
function M.submit(session)
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
