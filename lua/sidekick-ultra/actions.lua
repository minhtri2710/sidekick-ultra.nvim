---The user-facing actions: send, prompt, select, focus, close, render.
local errors = require("sidekick-ultra.errors")
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
---@field focus? boolean focus the session's pane or block afterwards
---@field all? boolean (close) detach every match

---Sleep for `ms`. A field so tests can observe the wait.
M.sleep = function(ms)
  vim.uv.sleep(ms)
end

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

---@return boolean
local function in_visual()
  return vim.fn.mode():find("^[vV\22]") ~= nil
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

---Deliver `text` to one session: [focus-in, wait], text and LF, [Enter], [focus]. Stops at the first refusal.
---@param session sidekick_ultra.Session
---@param text string
---@param opts sidekick_ultra.ActionOpts
local function deliver(session, text, opts)
  local tool = tools.get(session.tool)
  if tool and tool.mux_focus then
    if not call(session, "send", FOCUS_IN) then
      return
    end
    M.sleep(FOCUS_WAIT_MS)
  end
  -- A render that is a single newline is delivered as that newline alone.
  if not call(session, "send", text == "\n" and text or text .. "\n") then
    return
  end
  if opts.submit and not call(session, "submit") then
    return
  end
  if opts.focus then
    call(session, "focus")
  end
end

---Render a message or prompt against the current context and send it to the target session(s).
---@param opts? sidekick_ultra.ActionOpts
---@param snap? sidekick_ultra.Snapshot taken now when omitted
function M.send(opts, snap)
  opts = opts or {}
  snap = snap or snapshot.capture()
  local segments, err = compose(opts, snap)
  if not segments then
    errors.notify(err)
    return
  end
  if tools.format(segments) == "" then
    errors.notify(errors.new("nothing_to_send", "nothing to send"))
    return
  end
  target.with_target({ filter = filter_of(opts), attach = true }, function(sessions)
    if in_visual() then
      vim.cmd("normal! \27")
    end
    for _, session in ipairs(sessions) do
      local tool = tools.get(session.tool)
      deliver(session, tools.format(segments, tool and tool.location), opts)
    end
  end)
end

---Pick a prompt from the library and send it. Prompts that cannot render in this context are not listed.
---@param opts? sidekick_ultra.ActionOpts
function M.prompt(opts)
  opts = opts or {}
  local snap = snapshot.capture()
  local names = vim.tbl_keys(render.prompts())
  table.sort(names)
  local items = vim.tbl_filter(function(name)
    return render.build({ prompt = name }, snap) ~= nil
  end, names)
  vim.ui.select(items, {
    prompt = "sidekick-ultra prompt",
    format_item = function(name)
      return ("%-18s %s"):format(name, (render.display(name):gsub("\n", "\\n")))
    end,
  }, function(name)
    if name then
      M.send(vim.tbl_extend("force", opts, { prompt = name }), snap)
    end
  end)
end

---Pick a state, attach it, and optionally focus it.
---@param opts? sidekick_ultra.ActionOpts
function M.select(opts)
  opts = opts or {}
  target.pick(target.states(filter_of(opts)), {}, function(state)
    local session = target.attach_state(state)
    if session and opts.focus then
      call(session, "focus")
    end
  end)
end

---Focus the pane or block of the target session.
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
  local segments, err = compose(opts or {}, snapshot.capture())
  if not segments then
    errors.notify(err)
    return nil, err
  end
  return tools.format(segments), nil
end

return M
