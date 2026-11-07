---The rex backend: sessions are rex blocks. Every command is `<bin> --autostart=false [-S <server>] <subcommand>`.
---The shapes were checked against a live rex 0.0.1793377904-ge6592f (Rex Beta build 1696) in D3. What is still
---unverified is listed in tests/fixtures/rex/UNVERIFIED.txt.
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")
local proc = require("sidekick-ultra.proc")

---@type sidekick_ultra.Backend
local M = { name = "rex" }

---Where the Rex Beta app keeps its CLI. A field so specs can point it elsewhere.
M.bundle_bin = "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"

---@type { bin?: string, server?: string }
local options = {}
---The binary `available()` found when `setup()` ran; every command runs it.
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
  if vim.fn.executable(M.bundle_bin) == 1 then
    return true, M.bundle_bin, "bundle"
  end
  return false
end

---Replace the options and find the binary.
---@param opts { bin?: string, server?: string }
function M.setup(opts)
  options = { bin = opts.bin, server = opts.server }
  bin_path = select(2, M.available())
end

function M.inside()
  return vim.env.TERM_PROGRAM == "rex" and (vim.env.REX_SESSION or "") ~= "" and (vim.env.REX_BLOCK or "") ~= ""
end

---@param label string
---@param msg string
---@return sidekick_ultra.Error
local function failure(label, msg)
  return errors.new("backend_error", msg, { backend = M.name, cmd = label })
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

---@param label string subcommand label for errors
---@param ... string
---@return any? decoded
---@return sidekick_ultra.Error? err
local function json(label, ...)
  return exec.json(command(...), { backend = M.name, cmd = label })
end

---@param label string
---@param ... string
---@return true? ok
---@return sidekick_ultra.Error? err
local function run(label, ...)
  local _, err = exec.check(command(...), { backend = M.name, cmd = label })
  if err then
    return nil, err
  end
  return true
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
  local view, err = json("session.view", "api", "call", "-s", sid, "session.view")
  if not view then
    return nil, err
  end
  local ids = view_blocks(view)
  if not ids then
    return nil, failure("session.view", "rex printed an unexpected session view")
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
  local data, err = json("process", "block", "call", "-s", sid, "-b", bid, "process")
  if not data then
    return nil, err
  end
  if type(data) ~= "table" then
    return nil, failure("process", "rex printed an unexpected process view")
  end
  local fg = data.foreground
  if fg == nil then
    return nil
  end
  if type(fg) ~= "table" or type(fg.pid) ~= "number" then
    return nil, failure("process", "rex printed an unexpected process view")
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
  return proc.tool_of(M.name, configured, fg.pid, words)
end

---Session record for a block whose foreground process runs `tool_name`. Nil (not running here) when the pid is not
---visible to this nvim.
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
    return nil, failure("process", "rex printed no working directory for block " .. bid)
  end
  return {
    id = "rex:" .. bid,
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
  local listing, err = json("ls", "ls", "--json")
  if not listing then
    -- Exit 4 is "server unreachable": no server means no sessions, not a failure worth a toast on every discovery.
    if err.code == 4 then
      return {}
    end
    return nil, err
  end
  local sessions = children(listing, "sessions")
  if not sessions then
    return nil, failure("ls", "rex printed an unexpected session list")
  end
  local ret = {}
  for _, entry in ipairs(sessions) do
    if type(entry) ~= "table" or type(entry.session_id) ~= "string" then
      return nil, failure("ls", "rex printed an unexpected session list")
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

---Split a new block to the right of nvim's own block, without focus, running the tool.
---Chosen from the installed binary's help text (`rex split -b BLOCK --split=right -c DIR --focus=false --json -- CMD`).
---`split` shows no environment flag, so a non-empty `opts.env` goes in front of the command as `/usr/bin/env K=V`.
---@param tool sidekick_ultra.Tool
---@param opts sidekick_ultra.StartOpts
function M.start(tool, opts)
  local sid, anchor = vim.env.REX_SESSION, vim.env.REX_BLOCK
  local args = { "split", "-s", sid, "-b", anchor, "--split=right", "-c", opts.cwd, "--focus=false", "--json", "--" }
  vim.list_extend(args, exec.env_prefix(opts.env))
  vim.list_extend(args, tool.cmd)
  local created, err = json("split", unpack(args))
  if not created then
    return nil, err
  end
  local ids = children(created, "block_ids")
  local bid = ids and ids[1]
  if type(bid) ~= "string" then
    return nil, failure("split", "rex printed no id for the new block")
  end

  -- The block is "running" at once: record whatever its foreground is now (the login shell or the command). The next
  -- discovery replaces this record with the tool's own pid, matched by id.
  local fg, fg_err = foreground(sid, bid)
  if fg_err then
    return nil, fg_err
  end
  if not fg then
    return nil, failure("split", ("block %s has no foreground process; it was left open"):format(bid))
  end
  local session, session_err = session_of(tool.name, sid, bid, fg)
  if not session and not session_err then
    return nil, failure("split", ("block %s is not visible to this nvim; it was left open"):format(bid))
  end
  return session, session_err
end

---Refuse when a `blocked` program-status record is owned by the session's foreground pid, or when the state cannot
---be read. Firstmate also accepts records owned by an ancestor of the foreground; v1 records only the foreground pid.
---@param session sidekick_ultra.Session
---@return true? ok
---@return sidekick_ultra.Error? err
local function guard(session)
  local data, err =
    json("program_status", "block", "call", "-s", session.session_id, "-b", session.block_id, "program_status")
  if not data then
    return nil,
      errors.new("status_unreadable", "cannot read the state of " .. session.id .. ": " .. err.msg, {
        backend = M.name,
        cmd = "program_status",
        code = err.code,
      })
  end
  local records = children(data, "records")
  local function unreadable()
    return errors.new(
      "status_unreadable",
      "rex printed an unexpected state for " .. session.id,
      { backend = M.name, cmd = "program_status" }
    )
  end
  if not records then
    return nil, unreadable()
  end
  for _, record in ipairs(records) do
    if type(record) ~= "table" or type(record.state) ~= "string" then
      return nil, unreadable()
    end
  end
  for _, record in ipairs(records) do
    if record.state == "blocked" and type(record.owner) == "table" and record.owner.pid == session.pid then
      return nil, errors.new("session_blocked", session.id .. " is waiting for an answer", { backend = M.name })
    end
  end
  return true
end

---@param session sidekick_ultra.Session
---@param text string
function M.send(session, text)
  local ok, err = guard(session)
  if not ok then
    return nil, err
  end
  return run("send", "send", "-s", session.session_id, "-b", session.block_id, "--", text)
end

---@param session sidekick_ultra.Session
function M.submit(session)
  return run("send-key", "send-key", "-s", session.session_id, "-b", session.block_id, "enter")
end

---`rex focus` takes a block or window as its target (help text of the installed binary).
---@param session sidekick_ultra.Session
function M.focus(session)
  return run("focus", "focus", "-s", session.session_id, session.block_id)
end

return M
