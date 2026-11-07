---The rex backend: sessions are rex blocks. Every command is `<bin> --autostart=false [-S <server>] <subcommand>`.
---The shapes were checked against a live rex 0.0.1793377904-ge6592f (Rex Beta build 1696). What is still
---unverified is listed in tests/fixtures/rex/UNVERIFIED.txt.
local contract = require("sidekick-ultra.backend")
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")
local proc = require("sidekick-ultra.proc")

---@type sidekick_ultra.Backend
local M = { name = "rex" }

---Where the Rex Beta app keeps its CLI.
local BUNDLE_BIN = "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"

---@type { bin?: string, server?: string }
local options = {}
---@type string?
local bin_path

---@return boolean ok
---@return string? path
---@return string? source "option"|"PATH"|"bundle"
function M.available()
  if options.bin then
    -- A configured binary is the only candidate: a wrong path must not quietly run another rex.
    local path = vim.fn.exepath(vim.fs.normalize(options.bin))
    if path == "" then
      return false
    end
    return true, path, "option"
  end
  local ok, path, source = exec.on_path("rex")
  if ok then
    return ok, path, source
  end
  if vim.fn.executable(BUNDLE_BIN) == 1 then
    return true, BUNDLE_BIN, "bundle"
  end
  return false
end

---@param opts { bin?: string, server?: string }
function M.setup(opts)
  options = { bin = opts.bin, server = opts.server }
  bin_path = select(2, M.available())
end

---REX_SESSION and REX_BLOCK also reach processes that do not run in rex (the paseo daemon passes them to every agent
---it starts), so `TERM_PROGRAM` is part of the test.
function M.inside()
  return vim.env.TERM_PROGRAM == "rex" and (vim.env.REX_SESSION or "") ~= "" and (vim.env.REX_BLOCK or "") ~= ""
end

---The full argv for a subcommand. Never relies on REX_SERVER (rex ignored it in firstmate's runs).
---@param ... string
---@return string[] argv
local function command(...)
  local argv = { bin_path, "--autostart=false" }
  if options.server then
    vim.list_extend(argv, { "-S", options.server })
  end
  return vim.list_extend(argv, { ... })
end

---`parent[key]` as a list: absent or null is empty, a non-list is nil (malformed).
---@param parent any
---@param key string
---@return table[]?
local function children(parent, key)
  if type(parent) ~= "table" then
    return nil
  end
  local value = parent[key]
  if value == nil then
    return {}
  end
  if type(value) == "table" and vim.islist(value) then
    return value
  end
end

---@param view any a `session.view` response
---@return string[]? ids nil when the view has an unexpected shape
local function view_blocks(view)
  local ids = {}
  local windows = children(view, "windows")
  for _, window in ipairs(windows or {}) do
    local layers = children(window, "layers")
    if not layers then
      return nil
    end
    for _, layer in ipairs(layers) do
      local blocks = children(layer, "blocks")
      if not blocks then
        return nil
      end
      for _, block in ipairs(blocks) do
        if type(block) ~= "table" or type(block.block_id) ~= "string" then
          return nil
        end
        table.insert(ids, block.block_id)
      end
    end
  end
  return windows and ids or nil
end

---@param sid string
---@return string[]? ids
---@return sidekick_ultra.Error? err
local function block_ids(sid)
  local view, err = exec.json(command("api", "call", "-s", sid, "session.view"))
  if not view then
    return nil, err
  end
  local ids = view_blocks(view)
  if not ids then
    return nil, errors.new("backend_error", "rex printed an unexpected session view")
  end
  return ids
end

---The block's foreground process: `{pid, name?, argv0?, cwd?}`, or nil without one. Only pid, name and cwd are kept
---(argv0 is read for the tool match and never stored).
---@param sid string
---@param bid string
---@return table? fg
---@return sidekick_ultra.Error? err
local function foreground(sid, bid)
  local data, err = exec.json(command("block", "call", "-s", sid, "-b", bid, "process"))
  if not data then
    return nil, err
  end
  if type(data) ~= "table" then
    return nil, errors.new("backend_error", "rex printed an unexpected process view")
  end
  local fg = data.foreground
  if fg == nil then
    return nil
  end
  if type(fg) ~= "table" or type(fg.pid) ~= "number" then
    return nil, errors.new("backend_error", "rex printed an unexpected process view")
  end
  return { pid = fg.pid, name = fg.name, argv0 = fg.argv0, cwd = fg.cwd }
end

---The configured tool a foreground process runs. argv0 first, then name: Claude Code's `name` is its version while its
---`argv0` is "claude". A node or python script tool runs as its interpreter until it sets its own title, so then the
---script it runs is tested (see proc).
---@param configured table<string, sidekick_ultra.Tool>
---@param fg table
---@return string? tool_name
---@return sidekick_ultra.Error? err a failing ps
local function tool_of(configured, fg)
  local words = {}
  if type(fg.argv0) == "string" then
    table.insert(words, vim.fs.basename(fg.argv0))
  end
  if type(fg.name) == "string" then
    table.insert(words, fg.name)
  end
  return proc.tool_of(configured, fg.pid, words)
end

---Nil (not running here) when the pid is not visible to this nvim.
---@param tool_name string
---@param sid string
---@param bid string
---@param fg table
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
local function session_of(tool_name, sid, bid, fg)
  local name = proc.name(fg.pid)
  if not name then
    return nil
  end
  if type(fg.cwd) ~= "string" or fg.cwd == "" then
    return nil, errors.new("backend_error", "rex printed no working directory for block " .. bid)
  end
  return {
    id = M.name .. ":" .. bid,
    backend = M.name,
    tool = tool_name,
    cwd = fg.cwd,
    pid = fg.pid,
    proc_name = name,
    session_id = sid,
    block_id = bid,
  }
end

---ponytail: discovery costs 1 + sessions + blocks synchronous CLI calls. Fine for a handful of blocks; batch the reads
---through `rex do` (one Lua script, one call) when listing gets slow.
---@param configured table<string, sidekick_ultra.Tool>
function M.list(configured)
  local listing, err = exec.json(command("ls", "--json"))
  if not listing then
    -- Exit 4 is "server unreachable": no server, no sessions.
    if err.code == 4 then
      return {}
    end
    return nil, err
  end
  local sessions = children(listing, "sessions")
  if not sessions then
    return nil, errors.new("backend_error", "rex printed an unexpected session list")
  end
  local ret = {}
  for _, entry in ipairs(sessions) do
    if type(entry) ~= "table" or type(entry.session_id) ~= "string" then
      return nil, errors.new("backend_error", "rex printed an unexpected session list")
    end
    local ids, ids_err = block_ids(entry.session_id)
    if not ids then
      return nil, ids_err
    end
    for _, bid in ipairs(ids) do
      local fg, fg_err = foreground(entry.session_id, bid)
      if fg_err then
        return nil, fg_err
      end
      local name, match_err
      if fg then
        name, match_err = tool_of(configured, fg)
      end
      if match_err then
        return nil, match_err
      end
      if name then
        local session, session_err = session_of(name, entry.session_id, bid, fg)
        if session_err then
          return nil, session_err
        end
        table.insert(ret, session)
      end
    end
  end
  return ret
end

---The session record of the block `start` just split.
---@param tool sidekick_ultra.Tool
---@param sid string
---@param bid string
---@return sidekick_ultra.Session? session
---@return sidekick_ultra.Error? err
local function started_session(tool, sid, bid)
  local fg, fg_err = foreground(sid, bid)
  if fg_err then
    return nil, fg_err
  end
  if not fg then
    return nil, errors.new("backend_error", "the new block has no foreground process")
  end
  local session, session_err = session_of(tool.name, sid, bid, fg)
  if not session and not session_err then
    return nil, errors.new("backend_error", "the new block is not visible to this nvim")
  end
  return session, session_err
end

---Split a new block to the right of nvim's own block, without focus, running the tool.
---Chosen from the installed binary's help text (`rex split -b BLOCK --split=right -c DIR --focus=false --json -- CMD`).
---`split` shows no environment flag.
---@param tool sidekick_ultra.Tool
---@param opts sidekick_ultra.StartOpts
function M.start(tool, opts)
  local sid, anchor = vim.env.REX_SESSION, vim.env.REX_BLOCK
  local args = { "split", "-s", sid, "-b", anchor, "--split=right", "-c", opts.cwd, "--focus=false", "--json", "--" }
  vim.list_extend(args, exec.env_prefix(opts.env))
  vim.list_extend(args, tool.cmd)
  local created, err = exec.json(command(unpack(args)))
  if not created then
    return nil, err
  end
  local ids = children(created, "block_ids")
  local bid = ids and ids[1]
  if type(bid) ~= "string" then
    return nil, errors.new("backend_error", "rex printed no id for the new block")
  end

  local session, session_err = started_session(tool, sid, bid)
  if session_err then
    session_err.msg = ("%s; block %s was left open"):format(session_err.msg, bid)
  end
  return session, session_err
end

---Whether a `blocked` program-status record is owned by the session's foreground pid. Firstmate also accepts records
---owned by an ancestor of the foreground; v1 records only the foreground pid.
---@param session sidekick_ultra.Session
---@return boolean? blocked
---@return sidekick_ultra.Error? err
local function is_blocked(session)
  local data, err =
    exec.json(command("block", "call", "-s", session.session_id, "-b", session.block_id, "program_status"))
  if not data then
    return nil, err
  end
  local unexpected = errors.new("backend_error", "rex printed an unexpected program status")
  local records = children(data, "records")
  if not records then
    return nil, unexpected
  end
  local blocked = false
  for _, record in ipairs(records) do
    if type(record) ~= "table" or type(record.state) ~= "string" then
      return nil, unexpected
    end
    if record.state == "blocked" and type(record.owner) == "table" and record.owner.pid == session.pid then
      blocked = true
    end
  end
  return blocked
end

---@param session sidekick_ultra.Session
---@param text string
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.send(session, text)
  local ok, err = contract.guard_send(session, is_blocked)
  if not ok then
    return nil, err
  end
  return exec.check(command("send", "-s", session.session_id, "-b", session.block_id, "--", text))
end

---@param session sidekick_ultra.Session
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.submit(session)
  return exec.check(command("send-key", "-s", session.session_id, "-b", session.block_id, "enter"))
end

---`rex focus` takes a block or window as its target (help text of the installed binary).
---@param session sidekick_ultra.Session
---@return sidekick_ultra.ExecResult? ok
---@return sidekick_ultra.Error? err
function M.focus(session)
  return exec.check(command("focus", "-s", session.session_id, session.block_id))
end

return M
