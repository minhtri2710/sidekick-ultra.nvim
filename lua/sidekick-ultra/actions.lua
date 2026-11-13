---The user-facing actions: send, prompt, select, focus, close, render. They own every focus decision.
local errors = require("sidekick-ultra.errors")
local location = require("sidekick-ultra.location")
local picker = require("sidekick-ultra.picker")
local registry = require("sidekick-ultra.registry")
local render = require("sidekick-ultra.context.render")
local snapshot = require("sidekick-ultra.context.snapshot")
local target = require("sidekick-ultra.target")

local M = {}

---@class sidekick_ultra.ActionOpts
---@field name? string tool filter
---@field filter? sidekick_ultra.Filter
---@field msg? string message template
---@field prompt? string prompt name
---@field submit? boolean press Enter after sending
---@field focus? boolean `true` focuses the session after the action; unset focuses only a tool the action started; `false` never
---@field all? boolean (close) detach every match

local FOCUS_IN = "\27[I"
local FOCUS_WAIT_MS = 50

---@param opts sidekick_ultra.ActionOpts
---@return sidekick_ultra.Filter
local function filter_of(opts)
  local filter = vim.deepcopy(opts.filter or {})
  if opts.name then
    filter.name = opts.name
  end
  return filter
end

---The one reading of `opts.focus`.
---@param opts sidekick_ultra.ActionOpts
---@return boolean always `focus = true`: focus the session, whether or not the action started its tool
---@return boolean on_start `focus` is not `false`: focus a tool the action started
local function focus_of(opts)
  return opts.focus == true, opts.focus ~= false
end

---Capture the editor state, leaving visual mode once a selection is recorded: no action keeps the editor in it. With a
---`range` (the `:SidekickUltra` range count) it first restores the last visual selection, so `{selection}` works
---from `:'<,'>SidekickUltra send ...`.
---@param range? integer
---@return sidekick_ultra.Snapshot
local function capture(range)
  if range and range > 0 then
    vim.cmd("normal! gv")
  end
  local snap = snapshot.capture()
  if snap.selection then
    vim.cmd("normal! \27")
  end
  return snap
end

---Call a backend method on a session that `target` has just handed to the action (`current` or `attach_state`), so its
---backend is registered.
---@param session sidekick_ultra.Session
---@param method "send"|"submit"|"focus"
---@return boolean
local function call(session, method, ...)
  local ok, err = registry.backend(session.backend)[method](session, ...)
  if not ok then
    errors.notify(err)
    return false
  end
  return true
end

---@param state sidekick_ultra.State the target
---@param segments (string|sidekick_ultra.Location)[]
---@param submit? boolean
---@return boolean delivered every step was accepted
local function deliver(state, segments, submit)
  local session = state.session
  local text = location.format(segments, state.tool.location)
  if state.tool.mux_focus then
    if not call(session, "send", FOCUS_IN, state.tool) then
      return false
    end
    vim.uv.sleep(FOCUS_WAIT_MS)
  end
  -- A trailing space closes a tool's open `@` file-mention completion, which would otherwise take the line feed.
  local sent = text == "\n" and text or text .. (text:find("%s$") and "" or " ") .. "\n"
  if not call(session, "send", sent, state.tool) then
    return false
  end
  return not submit or call(session, "submit")
end

---Render a message or prompt against the current context and send it to the target session. A tool this starts is
---focused before the text, and `focus = true` focuses the session again after a delivery.
---@param opts? sidekick_ultra.ActionOpts
---@param range? integer the command's range count
function M.send(opts, range)
  opts = opts or {}
  local segments, err = render.build(opts, capture(range))
  if not segments then
    errors.notify(err or errors.new("nothing_to_send", "nothing to send"))
    return
  end
  target.with_target(filter_of(opts), function(state, started)
    local always, on_start = focus_of(opts)
    if started and on_start then
      call(state.session, "focus")
    end
    if deliver(state, segments, opts.submit) and always then
      call(state.session, "focus")
    end
  end)
end

---Pick the target session first, then a prompt from the library, and send it to that session. The picker previews
---the exact text for that session's tool. Prompts that cannot render in this context are not listed. A tool this
---starts is focused once the picker closes (not before, which would take the keys from it), and `focus = true` focuses
---the session after a delivery; either way it is focused once.
---@param opts? sidekick_ultra.ActionOpts
---@param range? integer the command's range count
function M.prompt(opts, range)
  opts = opts or {}
  local snap = capture(range)
  if opts.msg then
    local _, err = render.build({ msg = opts.msg }, snap)
    if err then
      errors.notify(err)
      return
    end
  end
  local names = vim.tbl_keys(render.prompts())
  table.sort(names)
  local renders, listed = {}, {}
  for _, name in ipairs(names) do
    local segments = render.build({ msg = opts.msg, prompt = name }, snap)
    if segments then
      renders[name] = segments
      table.insert(listed, name)
    end
  end
  if #listed == 0 then
    picker.select({}, function() end)
    return
  end
  target.with_target(filter_of(opts), function(state, started)
    local items = vim.tbl_map(function(name)
      return {
        name = name,
        display = render.display(name),
        preview = { text = location.format(renders[name], state.tool.location) },
      }
    end, listed)
    picker.select(items, function(item)
      local current = target.current(state)
      if not current then
        return
      end
      local delivered = item ~= nil and deliver(current, renders[item.name], opts.submit)
      local always, on_start = focus_of(opts)
      if (delivered and always) or (started and on_start) then
        call(current.session, "focus")
      end
    end)
  end)
end

---Pick a state and attach it. A tool it starts is focused unless `focus = false`; `focus = true` also focuses a
---session that was already running.
---@param opts? sidekick_ultra.ActionOpts
function M.select(opts)
  opts = opts or {}
  target.pick(target.states(filter_of(opts)), {}, function(state)
    local session, started = target.attach_state(state)
    local always, on_start = focus_of(opts)
    if session and (always or (started and on_start)) then
      call(session, "focus")
    end
  end)
end

---Focus the pane or block of the target session. It always focuses, whatever `opts.focus` is.
---@param opts? sidekick_ultra.ActionOpts
function M.focus(opts)
  opts = opts or {}
  target.with_target(filter_of(opts), function(state)
    call(state.session, "focus")
  end)
end

---Detach matching attached sessions. Never stops the tool or closes its pane.
---@param opts? sidekick_ultra.ActionOpts
function M.close(opts)
  opts = opts or {}
  target.with_attached(filter_of(opts), { one = not opts.all }, function(state)
    if registry.detach(state.session.id) then
      errors.info("Detached from " .. state.session.tool)
    end
  end)
end

---Render without sending.
---@param opts? sidekick_ultra.ActionOpts
---@return string? text
---@return sidekick_ultra.Error? err
function M.render(opts)
  local segments, err = render.build(opts or {}, capture())
  if err then
    errors.notify(err)
    return nil, err
  end
  return location.format(segments or {}), nil
end

return M
