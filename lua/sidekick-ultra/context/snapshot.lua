---Captures what the action was invoked on: the window's buffer, directory, cursor and selection. Sources read the
---buffer's contents and the rest of the editor's state when they render.

---@class sidekick_ultra.Selection
---@field kind "char"|"line"|"block"
---@field from integer[] {row, col}, 1-based, the earlier mark
---@field to integer[] {row, col}, 1-based, the later mark
---@field to_eol boolean the cursor was moved with `$`: a block runs to the end of every line

---@class sidekick_ultra.Snapshot
---@field buf integer
---@field cwd string
---@field cursor integer[] {row, col}, both 1-based (col is the byte column)
---@field selection? sidekick_ultra.Selection

local M = {}

local KIND = { v = "char", V = "line", ["\22"] = "block" }

---@return sidekick_ultra.Snapshot
function M.capture()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  ---@type sidekick_ultra.Snapshot
  local snap = {
    buf = vim.api.nvim_win_get_buf(win),
    cwd = vim.fn.getcwd(win),
    cursor = { cursor[1], cursor[2] + 1 },
  }

  local kind = KIND[vim.fn.mode()]
  if kind then
    local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
    local from, to = { a[2], a[3] }, { b[2], b[3] }
    if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
      from, to = to, from
    end
    snap.selection = { kind = kind, from = from, to = to, to_eol = vim.fn.winsaveview().curswant == vim.v.maxcol }
  end
  return snap
end

return M
