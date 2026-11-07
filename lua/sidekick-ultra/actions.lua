---The user-facing actions: send, prompt, select, focus, close, render. They own every focus decision.
local errors = require("sidekick-ultra.errors")
local picker = require("sidekick-ultra.picker")
local registry = require("sidekick-ultra.registry")
local render = require("sidekick-ultra.context.render")
local snapshot = require("sidekick-ultra.context.snapshot")
local target = require("sidekick-ultra.target")
local tools = require("sidekick-ultra.tools")

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

---Capture the editor state, leaving visual mode once a selection is recorded: no action keeps the editor in it.
---@return sidekick_ultra.Snapshot
local function capture()
  local snap = snapshot.capture()
  if snap.selection then
    vim.cmd("normal! \27")
  end
  return snap
end

---Run a backend method for a session; notify and return false on failure.
---@param session sidekick_ultra.Session
---@param method "send"|"submit"|"focus"
---@return boolean
local function call(session, method, ...)
  local backend = registry.backend(session.backend)
  if not backend then
    errors.notify(
      errors.new("backend_error", "backend not registered: " .. session.backend, { backend = session.backend })
    )
    return false
  end
  local ok, err = backend[method](session, ...)
  if not ok then
    errors.notify(err)
    return false
  end
  return true
end

---Render once into segments; each target's location style is applied when the text is written out.
---@param opts sidekick_ultra.ActionOpts
---@param snap sidekick_ultra.Snapshot
---@return (string|sidekick_ultra.Location)[]? segments
---@return sidekick_ultra.Error? err
local function compose(opts, snap)
  local msg = opts.msg
  if not msg and not opts.prompt and snap.selection then
    msg = "{selection}"
  end
  return render.build({ msg = msg, prompt = opts.prompt }, snap)
end

---Write the segments to the session in its tool's location style: [focus-in, wait], text and LF, [Enter]. Stops at
---the first refusal, which is notified.
---@param session sidekick_ultra.Session
---@param segments (string|sidekick_ultra.Location)[]
---@param submit? boolean
---@return boolean delivered every step was accepted
local function deliver(session, segments, submit)
  local tool = tools.get(session.tool)
  local text = tools.format(segments, tool and tool.location)
  if tool and tool.mux_focus then
    if not call(session, "send", FOCUS_IN) then
      return false
    end
    vim.uv.sleep(FOCUS_WAIT_MS)
  end
  if not call(session, "send", text == "\n" and text or text .. "\n") then
    return false
  end
  return not submit or call(session, "submit")
end

---Warn and return false when the render has no text to send.
---@param segments (string|sidekick_ultra.Location)[]
---@return boolean
local function has_text(segments)
  if tools.format(segments) == "" then
    errors.notify(errors.new("nothing_to_send", "nothing to send"))
    return false
  end
  return true
end

---Render a message or prompt against the current context and send it to the target session. A tool this starts is
---focused before the text, and `focus = true` focuses the session again after a delivery.
---@param opts? sidekick_ultra.ActionOpts
function M.send(opts)
  opts = opts or {}
  local segments, err = compose(opts, capture())
  if not segments then
    errors.notify(err)
    return
  end
  if not has_text(segments) then
    return
  end
  target.with_target({ filter = filter_of(opts), attach = true }, function(sessions, started)
    local session = sessions[1]
    local always, on_start = focus_of(opts)
    if started and on_start then
      call(session, "focus")
    end
    if deliver(session, segments, opts.submit) and always then
      call(session, "focus")
    end
  end)
end

---Pick the target session first, then a prompt from the library, and send it to that session. The picker previews
---the exact text for that session's tool. Prompts that cannot render in this context are not listed. A tool this
---starts is focused once the picker closes (not before, which would take the keys from it), and `focus = true` focuses
---the session after a delivery; either way it is focused once.
---@param opts? sidekick_ultra.ActionOpts
function M.prompt(opts)
  opts = opts or {}
  local snap = capture()
  if opts.msg then
    local _, err = compose({ msg = opts.msg }, snap)
    if err then
      errors.notify(err)
      return
    end
  end
  local names = vim.tbl_keys(render.prompts())
  table.sort(names)
  local renders, listed = {}, {}
  for _, name in ipairs(names) do
    local segments = compose(vim.tbl_extend("force", opts, { prompt = name }), snap)
    if segments then
      renders[name] = segments
      table.insert(listed, name)
    end
  end
  if #listed == 0 then
    picker.select({}, function() end)
    return
  end
  target.with_target({ filter = filter_of(opts), attach = true }, function(sessions, started)
    local session = sessions[1]
    local tool = tools.get(session.tool)
    local items = vim.tbl_map(function(name)
      return { name = name, preview = { text = tools.format(renders[name], tool and tool.location) } }
    end, listed)
    picker.select(items, function(item)
      local delivered = item ~= nil
        and has_text(renders[item.name])
        and deliver(session, renders[item.name], opts.submit)
      local always, on_start = focus_of(opts)
      if (delivered and always) or (started and on_start) then
        call(session, "focus")
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
  target.with_target({ filter = filter_of(opts), attach = true }, function(sessions)
    for _, session in ipairs(sessions) do
      call(session, "focus")
    end
  end)
end

---Detach matching attached sessions. Never stops the tool or closes its pane.
---@param opts? sidekick_ultra.ActionOpts
function M.close(opts)
  opts = opts or {}
  target.with_target({ filter = filter_of(opts), all = opts.all }, function(sessions)
    for _, session in ipairs(sessions) do
      if registry.detach(session.id) then
        errors.info("Detached from " .. session.tool)
      end
    end
  end)
end

---Render without sending.
---@param opts? sidekick_ultra.ActionOpts
---@return string? text
---@return sidekick_ultra.Error? err
function M.render(opts)
  local segments, err = compose(opts or {}, capture())
  if not segments then
    errors.notify(err)
    return nil, err
  end
  return tools.format(segments), nil
end

return M
