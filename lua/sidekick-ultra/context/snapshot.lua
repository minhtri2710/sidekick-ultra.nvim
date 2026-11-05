---Captures the editor state an action works from. Rendering reads only this record, never the current window.

---@class sidekick_ultra.Selection
---@field kind "char"|"line"|"block"
---@field from integer[] {row, col}, 1-based, the earlier mark
---@field to integer[] {row, col}, 1-based, the later mark

---@class sidekick_ultra.Snapshot
---@field win integer
---@field buf integer
---@field cwd string
---@field cursor integer[] {row, col}, both 1-based (col is the byte column)
---@field selection? sidekick_ultra.Selection

local M = {}

local KIND = { v = "char", V = "line", ["\22"] = "block" }

---Capture the current window.
---@return sidekick_ultra.Snapshot
function M.capture()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  ---@type sidekick_ultra.Snapshot
  local snap = {
    win = win,
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
    snap.selection = { kind = kind, from = from, to = to }
  end
  return snap
end

---A file buffer is listed, has an empty or help buftype, and is named after a readable file.
---@param buf integer
---@return boolean
function M.is_file(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].buflisted then
    return false
  end
  local buftype = vim.bo[buf].buftype
  if buftype ~= "" and buftype ~= "help" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fn.filereadable(name) == 1
end

---@param name string
---@param dir string
---@return string?
local function relative(name, dir)
  dir = dir:gsub("/+$", "")
  if name:sub(1, #dir + 1) == dir .. "/" then
    return name:sub(#dir + 2)
  end
end

---The buffer's path as shown after `@`: relative to `cwd` when under it, else absolute.
---@param buf integer
---@param cwd string
---@return string
function M.path(buf, cwd)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return "[No Name]"
  end
  local rel = relative(name, cwd)
  if rel then
    return rel
  end
  -- /tmp vs /private/tmp: compare again with symlinks resolved.
  local real_name, real_cwd = vim.uv.fs_realpath(name), vim.uv.fs_realpath(cwd)
  return real_name and real_cwd and relative(real_name, real_cwd) or name
end

return M
