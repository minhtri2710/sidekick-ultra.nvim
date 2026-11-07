---The prompt picker: `vim.ui.select` over prompt items, sized for snacks.nvim, whose `select` preset hides the preview.
---Other pickers ignore the `snacks` options. The size rules: the box fits its content, never grows wider than snacks'
---own `select` picker, and its preview takes up to half the screen.
local render = require("sidekick-ultra.context.render")

local M = {}

local PICKER_MIN_WIDTH = 40
local PICKER_MARGIN = 8 -- columns left free beside the box (its own border adds 2 more)
local LIST_MIN, LIST_MAX = 2, 10
-- Rows in the box besides the list and the preview text: the input and its bottom border, and the preview's top border.
local BOX_CHROME = 3
local BOX_FREE_ROWS = 4 -- rows left free below the box height (its border and the command line)
local NUMBER_MIN = 4 -- the preview's number column, which snacks leaves on (`numberwidth` default)

---@class sidekick_ultra.PromptItem
---@field name string prompt name
---@field preview { text: string } the exact text that would be sent

---@param item sidekick_ultra.PromptItem
---@return string
local function label(item)
  return ("%-18s %s"):format(item.name, (render.display(item.name):gsub("\n", "\\n")))
end

---Size the snacks `select` box to the longest listed prompt. snacks sizes a picker once, when it opens, so the box fits
---the largest item, not the highlighted one. The sizes are the box `width` and `height` (inside the border), the
---list `height` and the preview `height`, all absolute (>= 1: `snacks/win.lua`, `M:dim`), so the box shrinks to fit
---the children (`snacks/layout.lua`, `M:update_box`). `select` turns the preview's `wrap` off whatever the user's
---`wrap` is, so a line takes one row and one longer than the width is cut at the edge. The width stops at the
---inner width snacks gives its own `select` picker: the preset (`layouts.lua`, `M.select`) is `width = 0.5` (less the
---border's 2 columns), `min_width = 80`, `max_width = 100`, applied in `snacks/win.lua`, `M:dim` (`size`, then the
---`ret.width` clamps). The box stays `BOX_FREE_ROWS` short of the screen while the chrome, one list
---row and one preview row fit in it (`lines >= 9`). Below that the box is its floor of 5 rows (7 with its border): a
---list row and a preview row are the least snacks can draw, and the box would clip or cover the command line.
---@param items sidekick_ultra.PromptItem[]
---@return table layout a snacks layout; its children keep the structure of the `select` preset (`layouts.lua`)
local function fit_layout(items)
  local columns, lines = vim.o.columns, vim.o.lines
  local need, rows = 0, 1
  for _, item in ipairs(items) do
    local text = vim.split(item.preview.text, "\n", { plain = true })
    local number = math.max(NUMBER_MIN, #tostring(#text) + 1)
    rows = math.max(rows, #text)
    -- A list row is the index, ". " and the label.
    need = math.max(need, #tostring(#items) + 2 + vim.fn.strdisplaywidth(label(item)))
    for _, line in ipairs(text) do
      need = math.max(need, vim.fn.strdisplaywidth(line) + number)
    end
  end
  local normal = math.min(math.max(math.floor(columns * 0.5) - 2, 80), 100)
  local width = math.min(math.max(need, PICKER_MIN_WIDTH), normal, columns - PICKER_MARGIN)

  local room = lines - BOX_FREE_ROWS - BOX_CHROME
  local list = math.max(math.min(math.max(#items, LIST_MIN), LIST_MAX, room - 1), 1)
  local preview = math.max(math.min(rows, math.floor(lines * 0.5), room - list), 1)

  -- selene: allow(mixed_table)
  return {
    layout = {
      backdrop = false,
      width = width,
      height = BOX_CHROME + list + preview,
      box = "vertical",
      border = true,
      title = "{title}",
      title_pos = "center",
      { win = "input", height = 1, border = "bottom" },
      { win = "list", border = "none", height = list },
      { win = "preview", title = "{preview}", height = preview, border = "top" },
    },
  }
end

---Open the picker. snacks hides the preview of `vim.ui.select` in its `select` preset
---(`snacks/picker/config/layouts.lua`, `M.select`), so `layout.layout` is given in full: a layout with children is
---used as is, without a preset (`snacks/picker/config/init.lua`, `M.layout`). `win.preview.wo.wrap = false` reaches the
---preview window (`snacks/picker/core/preview.lua`, `M.new` and `M:reset`) and nothing else turns it back on for these
---items, so `fit_layout` counts one row per line.
---@param items sidekick_ultra.PromptItem[]
---@param on_choice fun(item?: sidekick_ultra.PromptItem)
function M.select(items, on_choice)
  vim.ui.select(items, {
    prompt = "sidekick-ultra prompt",
    format_item = label,
    snacks = { preview = "preview", layout = fit_layout(items), win = { preview = { wo = { wrap = false } } } },
  }, on_choice)
end

return M
