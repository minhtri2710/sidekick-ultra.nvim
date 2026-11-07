---File locations in sent text. Sources build `Location` records; they are written in the target tool's style only
---when the text is sent (`format`), so a source never knows the style. This module owns the record, its kinds, the
---styles, and what makes a buffer a file worth naming.

---@alias sidekick_ultra.LocationStyle "plain"|"claude"|"escaped"

---@class sidekick_ultra.Location
---@field path string path as shown after `@`
---@field kind "file"|"line"|"position"
---@field r1? integer 1-based first row (line and position kinds)
---@field c1? integer 1-based first column (position kind)
---@field r2? integer
---@field c2? integer

local M = {}

---@type sidekick_ultra.LocationStyle[]
M.styles = { "plain", "claude", "escaped" }
M.DEFAULT_STYLE = "plain"
M.NO_NAME = "[No Name]"

local KINDS = { file = true, line = true, position = true }

---Whether `segment` is a record `text` can write: a string path, a known kind, and the integer rows and columns that
---kind needs (`r1` for line, `r1` and `c1` for position); `r2` and `c2` are optional.
---@param segment table
---@return boolean
function M.is_location(segment)
  local function int(v)
    return type(v) == "number" and v % 1 == 0
  end
  local kind = segment.kind
  if type(segment.path) ~= "string" or not KINDS[kind] then
    return false
  end
  for _, field in ipairs({ "r1", "c1", "r2", "c2" }) do
    local needed = (field == "r1" and kind ~= "file") or (field == "c1" and kind == "position")
    if segment[field] == nil and needed or segment[field] ~= nil and not int(segment[field]) then
      return false
    end
  end
  return true
end

---A file record: the path alone.
---@param path string
---@return sidekick_ultra.Location
function M.file(path)
  return { path = path, kind = "file" }
end

---A line record from a 1-based first and last row.
---@param path string
---@param r1 integer
---@param r2 integer
---@return sidekick_ultra.Location
function M.line(path, r1, r2)
  return { path = path, kind = "line", r1 = r1, r2 = r2 }
end

---A position record from 1-based start and optional end. The end defaults to the start; on one row it is never
---before the start column, and on a later row it is at least column 1.
---@param path string
---@param r1 integer
---@param c1 integer
---@param r2? integer
---@param c2? integer
---@return sidekick_ultra.Location
function M.position(path, r1, c1, r2, c2)
  r2 = r2 or r1
  c2 = math.max(c2 or c1, r2 == r1 and c1 or 1)
  return { path = path, kind = "position", r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
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
    return M.NO_NAME
  end
  local rel = relative(name, cwd)
  if rel then
    return rel
  end
  -- /tmp vs /private/tmp: compare again with symlinks resolved.
  local real_name, real_cwd = vim.uv.fs_realpath(name), vim.uv.fs_realpath(cwd)
  return real_name and real_cwd and relative(real_name, real_cwd) or name
end

local SAFE = "[^A-Za-z0-9/_.-]"

---@param loc sidekick_ultra.Location
---@return string rows
local function rows(loc)
  if not loc.r2 or loc.r2 == loc.r1 then
    return "L" .. loc.r1
  end
  return ("L%d-L%d"):format(loc.r1, loc.r2)
end

---@param loc sidekick_ultra.Location
---@return string
local function plain_suffix(loc)
  if loc.kind == "file" then
    return ""
  elseif loc.kind == "line" then
    return " :" .. rows(loc)
  end
  local r2, c2 = loc.r2 or loc.r1, loc.c2 or loc.c1
  if r2 == loc.r1 and c2 == loc.c1 then
    return (" :L%d:C%d"):format(loc.r1, loc.c1)
  elseif r2 == loc.r1 then
    return (" :L%d:C%d-C%d"):format(loc.r1, loc.c1, c2)
  end
  return (" :L%d:C%d-L%d:C%d"):format(loc.r1, loc.c1, r2, c2)
end

---Write a location the way `style` wants it in sent text.
---  plain:   `@path :L10-L20`, `@path :L10:C5`, `@path :L10:C5-C8`, `@path :L1:C2-L3:C4`
---  claude:  `@path#L10-20`, `@path#L10 :C5`, `@path#L10 :C5-C8`; a multi-line position keeps only its rows
---           (`#L1-3`); a path with unusual characters is double-quoted
---  escaped: plain, with every unusual path character backslash-escaped
---@param loc sidekick_ultra.Location
---@param style? sidekick_ultra.LocationStyle
---@return string
function M.text(loc, style)
  style = style or M.DEFAULT_STYLE
  if style == "escaped" then
    return "@" .. loc.path:gsub(SAFE, "\\%0") .. plain_suffix(loc)
  elseif style == "plain" then
    return "@" .. loc.path .. plain_suffix(loc)
  end

  local path = loc.path:find(SAFE) and ('"' .. loc.path .. '"') or loc.path
  local text = "@" .. path
  if loc.kind == "file" then
    return text
  end
  local r2 = loc.r2 or loc.r1
  local range = r2 == loc.r1 and tostring(loc.r1) or ("%d-%d"):format(loc.r1, r2)
  text = text .. "#L" .. range
  if loc.kind == "position" and r2 == loc.r1 then
    local c2 = loc.c2 or loc.c1
    text = text .. (c2 == loc.c1 and (" :C%d"):format(loc.c1) or (" :C%d-C%d"):format(loc.c1, c2))
  end
  return text
end

---Text of rendered output: strings as they are, location records written in `style`.
---@param segments (string|sidekick_ultra.Location)[]
---@param style? sidekick_ultra.LocationStyle
---@return string
function M.format(segments, style)
  local out = {}
  for i, segment in ipairs(segments) do
    out[i] = type(segment) == "string" and segment or M.text(segment, style)
  end
  return table.concat(out)
end

return M
