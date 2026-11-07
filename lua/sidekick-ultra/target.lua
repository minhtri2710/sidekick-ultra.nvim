---Choosing the session an action acts on: states (sessions and not-started tools), filters, sort order, the picker,
---the "with target" rule, and attaching or starting a chosen state. It never focuses: `actions` decides that.
local errors = require("sidekick-ultra.errors")
local registry = require("sidekick-ultra.registry")
local tools = require("sidekick-ultra.tools")

local M = {}

---One row of the listing: a running session, or a configured tool without one.
---@class sidekick_ultra.State
---@field name string tool name
---@field tool sidekick_ultra.Tool
---@field session? sidekick_ultra.Session
---@field installed boolean
---@field started boolean
---@field attached boolean
---@field cwd boolean the session runs in nvim's cwd (always true for a not-started tool)
---@field backend? string

---All fields optional; they combine with AND.
---@class sidekick_ultra.Filter
---@field name? string tool name
---@field session? string session id
---@field attached? boolean
---@field started? boolean
---@field installed? boolean
---@field cwd? boolean
---@field backend? string

---@class sidekick_ultra.TargetOpts
---@field filter? sidekick_ultra.Filter
---@field attach? boolean the action may attach (or start) a session when none is attached

---@param path string
---@return string
local function normalize(path)
  return (vim.fs.normalize(path):gsub("(.)/+$", "%1"))
end

---@param session sidekick_ultra.Session
---@param attached boolean
---@return sidekick_ultra.State?
local function session_state(session, attached)
  return {
    name = session.tool,
    tool = tools.get(session.tool),
    session = session,
    installed = true,
    started = true,
    attached = attached,
    cwd = normalize(session.cwd) == normalize(vim.fn.getcwd()),
    backend = session.backend,
  }
end

---@param state sidekick_ultra.State
---@param filter? sidekick_ultra.Filter
---@return boolean
local function matches(state, filter)
  filter = filter or {}
  if filter.name ~= nil and filter.name ~= state.name then
    return false
  end
  if filter.session ~= nil and (not state.session or state.session.id ~= filter.session) then
    return false
  end
  if filter.backend ~= nil and filter.backend ~= state.backend then
    return false
  end
  for _, key in ipairs({ "attached", "started", "installed", "cwd" }) do
    if filter[key] ~= nil and filter[key] ~= state[key] then
      return false
    end
  end
  return true
end

---Installed first, then states without a session or in nvim's cwd, then started, then tool name, then id.
---@param states sidekick_ultra.State[]
---@return sidekick_ultra.State[]
local function sort(states)
  local function rank(state)
    return {
      state.installed and 0 or 1,
      state.cwd and 0 or 1,
      state.started and 0 or 1,
      state.name,
      state.session and state.session.id or "",
    }
  end
  table.sort(states, function(a, b)
    local ra, rb = rank(a), rank(b)
    for i = 1, #ra do
      if ra[i] ~= rb[i] then
        return ra[i] < rb[i]
      end
    end
    return false
  end)
  return states
end

---Discover sessions once and list them with every configured tool, filtered and sorted.
---@param filter? sidekick_ultra.Filter
---@return sidekick_ultra.State[]
function M.states(filter)
  local sessions = registry.discover()
  local attached = {}
  for _, session in ipairs(registry.attached()) do
    attached[session.id] = true
  end
  local ret = {}
  local function add(state)
    if matches(state, filter) then
      table.insert(ret, state)
    end
  end
  for _, session in ipairs(sessions) do
    add(session_state(session, attached[session.id] == true))
  end
  for _, tool in ipairs(tools.list()) do
    add({
      name = tool.name,
      tool = tool,
      installed = tools.installed(tool),
      started = false,
      attached = false,
      cwd = true,
    })
  end
  return sort(ret)
end

---@param filter? sidekick_ultra.Filter
---@return sidekick_ultra.State[]
local function attached_states(filter)
  registry.check()
  local ret = {}
  for _, session in ipairs(registry.attached()) do
    local state = session_state(session, true)
    if matches(state, filter) then
      table.insert(ret, state)
    end
  end
  return sort(ret)
end

---@param state sidekick_ultra.State
---@return string
function M.label(state)
  local icon = state.attached and "◉" or state.started and "●" or state.installed and "○" or "✗"
  local label = icon .. " " .. state.name
  if state.session then
    label = ("%s [%s] %s"):format(label, state.session.backend, vim.fn.fnamemodify(state.session.cwd, ":~"))
  end
  return label
end

---Pick one of `states` with `vim.ui.select`. With `opts.auto` and exactly one state it is chosen directly; with none
---the `no_match` warning is shown. Cancelling does nothing.
---@param states sidekick_ultra.State[]
---@param opts? { auto?: boolean }
---@param cb fun(state: sidekick_ultra.State)
function M.pick(states, opts, cb)
  if #states == 0 then
    errors.notify(errors.new("no_match", "no matching tool or session"))
    return
  end
  if #states == 1 and opts and opts.auto then
    cb(states[1])
    return
  end
  vim.ui.select(states, { prompt = "sidekick-ultra", format_item = M.label }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

---Whether `state`, which a picker returned some time after it was listed, is still usable: its session's backend is
---registered and its tool configured. A `setup` that ran while the picker was open can have removed either. Reports
---the reason and returns false when it is not.
---@param state sidekick_ultra.State
---@return boolean
local function usable(state)
  local session = state.session
  if session and not registry.backend(session.backend) then
    errors.notify(errors.new("backend_error", "backend not registered: " .. session.backend))
    return false
  end
  if not tools.get(state.name) then
    errors.notify(errors.new("no_match", "tool no longer configured: " .. state.name))
    return false
  end
  return true
end

---Attach the chosen state, starting its tool first when it has no session. A state that is no longer usable (see
---`usable`) is refused with a notification. A missing tool is `not_installed` (its url is opened when it has one).
---@param state sidekick_ultra.State
---@return sidekick_ultra.Session? session
---@return boolean? started the session was started by this call
function M.attach_state(state)
  if not usable(state) then
    return nil
  end
  if not state.installed then
    errors.notify(
      errors.new("not_installed", state.name .. " is not installed", { tool = state.name, url = state.tool.url })
    )
    if state.tool.url then
      local obj, err = vim.ui.open(state.tool.url)
      if obj then
        errors.info("Opened " .. state.tool.url)
      else
        errors.message(vim.log.levels.WARN, ("Could not open %s: %s"):format(state.tool.url, tostring(err)))
      end
    end
    return nil
  end
  local session, started = state.session, false
  if not session then
    local err
    session, err = registry.start(state.tool)
    if not session then
      errors.notify(err)
      return nil
    end
    started = true
  end
  if registry.attach(session) then
    errors.info("Attached to " .. session.tool)
  end
  return session, started
end

local function no_match()
  errors.notify(errors.new("no_match", "no attached session matches"))
end

---Resolve the one state an action acts on and pass it to `cb`:
---no attached match and the action may attach: pick over every matching state and attach it;
---several attached matches: pick one of them, which must still be attached when the pick returns; otherwise the only
---attached match.
---`cb` also gets `started`: true when this call started the tool of the state it passes.
---@param opts sidekick_ultra.TargetOpts
---@param cb fun(state: sidekick_ultra.State, started?: boolean)
function M.with_target(opts, cb)
  local matching = attached_states(opts.filter)
  if #matching == 0 then
    if not opts.attach then
      no_match()
      return
    end
    M.pick(M.states(opts.filter), { auto = true }, function(state)
      local session, started = M.attach_state(state)
      if session then
        cb(session_state(session, true), started)
      end
    end)
  else
    M.pick(matching, { auto = true }, function(state)
      for _, session in ipairs(registry.attached()) do
        if session.id == state.session.id then
          cb(state)
          return
        end
      end
      no_match()
    end)
  end
end

---Pass every attached state that matches `filter` to `cb`.
---@param filter? sidekick_ultra.Filter
---@param cb fun(state: sidekick_ultra.State)
function M.with_attached(filter, cb)
  local matching = attached_states(filter)
  if #matching == 0 then
    no_match()
    return
  end
  for _, state in ipairs(matching) do
    cb(state)
  end
end

return M
