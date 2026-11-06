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
---@field focus? boolean focus the session's pane or block; false also skips the focus of a tool this starts
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
---@return boolean reached_focus true when it got to its own focus step, whether or not that focus succeeded
local function deliver(session, text, opts)
  local tool = tools.get(session.tool)
  if tool and tool.mux_focus then
    if not call(session, "send", FOCUS_IN) then
      return false
    end
    M.sleep(FOCUS_WAIT_MS)
  end
  -- A render that is a single newline is delivered as that newline alone.
  if not call(session, "send", text == "\n" and text or text .. "\n") then
    return false
  end
  if opts.submit and not call(session, "submit") then
    return false
  end
  if not opts.focus then
    return false
  end
  call(session, "focus")
  return true
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

---Leave visual mode, then write the render to each session in its tool's location style.
---@param sessions sidekick_ultra.Session[]
---@param segments (string|sidekick_ultra.Location)[]
---@param opts sidekick_ultra.ActionOpts
---@return boolean reached_focus whether the last delivery reached its own focus
local function write(sessions, segments, opts)
  if in_visual() then
    vim.cmd("normal! \27")
  end
  local reached_focus = false
  for _, session in ipairs(sessions) do
    local tool = tools.get(session.tool)
    reached_focus = deliver(session, tools.format(segments, tool and tool.location), opts)
  end
  return reached_focus
end

---Render a message or prompt against the current context and send it to the target session(s).
---@param opts? sidekick_ultra.ActionOpts
function M.send(opts)
  opts = opts or {}
  local segments, err = compose(opts, snapshot.capture())
  if not segments then
    errors.notify(err)
    return
  end
  if not has_text(segments) then
    return
  end
  target.with_target({ filter = filter_of(opts), attach = true, focus = opts.focus }, function(sessions)
    write(sessions, segments, opts)
  end)
end

---@param item table
---@return string
local function label(item)
  return ("%-18s %s"):format(item.name, (render.display(item.name):gsub("\n", "\\n")))
end

local PICKER_MIN_WIDTH = 40
local PICKER_MARGIN = 8 -- columns left free beside the box (its own border adds 2 more)
local LIST_MIN, LIST_MAX = 2, 10
-- Rows in the box besides the list and the preview text: the input and its bottom border, and the preview's top border.
local BOX_CHROME = 3
local BOX_FREE_ROWS = 4 -- rows left free below the box height (its border and the command line)
local NUMBER_MIN = 4 -- the preview's number column, which snacks leaves on (`numberwidth` default)

---Size the snacks `select` box to the longest listed prompt. snacks sizes a picker once, when it opens, so the box fits
---the largest item, not the highlighted one. The sizes are the box `width` and `height` (inside the border), the
---list `height` and the preview `height`, all absolute (>= 1: `snacks/win.lua`, `M:dim`), so the box shrinks to fit
---the children (`snacks/layout.lua`, `M:update_box`). The preview wraps (snacks sets no `wrap` there), so a line takes
---`ceil(width / text width)` rows.
---@param items table[]
---@return table layout a snacks layout; its children keep the structure of the `select` preset (`layouts.lua`)
local function fit_layout(items)
  local columns, lines = vim.o.columns, vim.o.lines
  local texts, number = {}, {}
  local need = 0
  for i, item in ipairs(items) do
    texts[i] = vim.split(item.preview.text, "\n", { plain = true })
    number[i] = math.max(NUMBER_MIN, #tostring(#texts[i]) + 1)
    -- A list row is the index, ". " and the label; the list does not wrap.
    need = math.max(need, #tostring(#items) + 2 + vim.fn.strdisplaywidth(label(item)))
    for _, line in ipairs(texts[i]) do
      need = math.max(need, vim.fn.strdisplaywidth(line) + number[i])
    end
  end
  local width = math.min(math.max(need, PICKER_MIN_WIDTH), columns - PICKER_MARGIN)

  local rows = 1
  for i in ipairs(items) do
    local count = 0
    for _, line in ipairs(texts[i]) do
      count = count + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / math.max(width - number[i], 1)))
    end
    rows = math.max(rows, count)
  end
  local list = math.min(math.max(#items, LIST_MIN), LIST_MAX)
  local height = math.min(BOX_CHROME + list + math.min(rows, math.floor(lines * 0.5)), lines - BOX_FREE_ROWS)
  local preview = math.max(height - BOX_CHROME - list, 1)

  -- selene's mixed_table rule rejects the preset's dict-plus-children literal, so the children are added after.
  local box = {
    backdrop = false,
    width = width,
    height = BOX_CHROME + list + preview,
    box = "vertical",
    border = true,
    title = "{title}",
    title_pos = "center",
  }
  vim.list_extend(box, {
    { win = "input", height = 1, border = "bottom" },
    { win = "list", border = "none", height = list },
    { win = "preview", title = "{preview}", height = preview, border = "top" },
  })
  return { layout = box }
end

---Open the prompt picker. snacks hides the preview of `vim.ui.select` in its `select` preset
---(`snacks/picker/config/layouts.lua`, `M.select`), so `layout.layout` is given in full: a layout with children is
---used as is, without a preset (`snacks/picker/config/init.lua`, `M.layout`). Other pickers ignore `snacks`.
---@param items table[]
---@param on_choice fun(item?: table)
local function select_prompt(items, on_choice)
  vim.ui.select(items, {
    prompt = "sidekick-ultra prompt",
    format_item = label,
    snacks = { preview = "preview", layout = fit_layout(items) },
  }, on_choice)
end

---Pick the target session first, then a prompt from the library, and send it to that session. The picker previews
---the exact text for that session's tool. Prompts that cannot render in this context are not listed. A tool this
---starts is focused once the picker closes (not before, which would take the keys from it) unless `focus = false`.
---@param opts? sidekick_ultra.ActionOpts
function M.prompt(opts)
  opts = opts or {}
  local snap = snapshot.capture()
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
    select_prompt({}, function() end)
    return
  end
  target.with_target({ filter = filter_of(opts), attach = true, focus = false }, function(sessions, started)
    local session = sessions[1]
    local tool = tools.get(session.tool)
    local items = vim.tbl_map(function(name)
      return { name = name, preview = { text = tools.format(renders[name], tool and tool.location) } }
    end, listed)
    select_prompt(items, function(item)
      local focused = item ~= nil and has_text(renders[item.name]) and write({ session }, renders[item.name], opts)
      -- A delivery that reached its own focus (`focus = true`) has focused the session already.
      if started and opts.focus ~= false and not focused then
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
    local session, started = target.attach_state(state, { focus = opts.focus })
    if session and opts.focus and not started then
      call(session, "focus")
    end
  end)
end

---Focus the pane or block of the target session. The focus at start is skipped: this focuses every session itself.
---@param opts? sidekick_ultra.ActionOpts
function M.focus(opts)
  opts = opts or {}
  target.with_target({ filter = filter_of(opts), attach = true, focus = false }, function(sessions)
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
