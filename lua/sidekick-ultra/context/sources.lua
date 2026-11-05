---Built-in placeholders. Each source takes a snapshot and `{style}` and returns lines, or nothing.
local snapshot = require("sidekick-ultra.context.snapshot")
local tools = require("sidekick-ultra.tools")

---@alias sidekick_ultra.Source fun(snap: sidekick_ultra.Snapshot, ctx: {style?: sidekick_ultra.LocationStyle}): string[]?

local M = {}

---@type table<string, sidekick_ultra.Source>
M.builtin = {}

---@param buf integer
---@param row integer
---@param col integer
---@return integer col clamped to the line (a `$` selection reports a huge column)
local function clamp_col(buf, row, col)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  return math.max(1, math.min(col, #line))
end

---@param snap sidekick_ultra.Snapshot
---@param ctx table
---@param kind "file"|"line"|"position"
---@return string[]?
local function located(snap, ctx, kind)
  if not snapshot.is_file(snap.buf) then
    return
  end
  local loc = { path = snapshot.path(snap.buf, snap.cwd), kind = kind }
  local sel = snap.selection
  if sel then
    loc.r1, loc.r2 = sel.from[1], sel.to[1]
    if kind == "position" and sel.kind == "line" then
      loc.kind = "line"
    elseif kind == "position" then
      loc.c1, loc.c2 = clamp_col(snap.buf, sel.from[1], sel.from[2]), clamp_col(snap.buf, sel.to[1], sel.to[2])
    end
  else
    loc.r1 = snap.cursor[1]
    loc.c1 = snap.cursor[2]
  end
  return { tools.location(loc, ctx.style) }
end

function M.builtin.position(snap, ctx)
  return located(snap, ctx, "position")
end

function M.builtin.file(snap, ctx)
  return located(snap, ctx, "file")
end

function M.builtin.line(snap, ctx)
  return located(snap, ctx, "line")
end

function M.builtin.buffers(snap, ctx)
  local ret = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if snapshot.is_file(buf) then
      local loc = { path = snapshot.path(buf, snap.cwd), kind = "file" }
      table.insert(ret, "- " .. tools.location(loc, ctx.style))
    end
  end
  return #ret > 0 and ret or nil
end

---Inclusive 1-based display columns `d1..d2` of `line`; `d2` nil means to the end of the line.
---@param line string
---@param d1 integer
---@param d2? integer
---@return string
local function cut(line, d1, d2)
  local out, before = {}, 0
  local starts = vim.str_utf_pos(line)
  for i, first in ipairs(starts) do
    local last = (starts[i + 1] or #line + 1) - 1
    local after = vim.fn.strdisplaywidth(line:sub(1, last))
    if after >= d1 and (not d2 or before + 1 <= d2) then
      table.insert(out, line:sub(first, last))
    end
    before = after
  end
  return table.concat(out)
end

---Display column where the character at byte `col` starts.
local function start_dcol(line, col)
  return vim.fn.strdisplaywidth(line:sub(1, col - 1)) + 1
end

---Display column where the character at byte `col` ends.
local function end_dcol(line, col)
  if line == "" then
    return 0
  end
  col = math.max(1, math.min(col, #line))
  return vim.fn.strdisplaywidth(line:sub(1, col + vim.str_utf_end(line, col)))
end

---The selected text: cut by kind, tabs expanded to `tabstop` spaces, common indent removed.
---@param snap sidekick_ultra.Snapshot
---@return string[]?
local function selected_text(snap)
  local sel = snap.selection
  if not sel then
    return
  end
  local r1, r2 = sel.from[1], sel.to[1]
  local lines = vim.api.nvim_buf_get_lines(snap.buf, r1 - 1, r2, false)

  if sel.kind == "char" then
    local first, last = lines[1], lines[#lines]
    local d1 = start_dcol(first, sel.from[2])
    local d2 = end_dcol(last, sel.to[2])
    if #lines == 1 then
      lines[1] = (" "):rep(d1 - 1) .. cut(first, d1, d2)
    else
      lines[1] = (" "):rep(d1 - 1) .. cut(first, d1)
      lines[#lines] = cut(last, 1, d2)
    end
  elseif sel.kind == "block" then
    local from_line, to_line = lines[1], lines[#lines]
    local d = {
      start_dcol(from_line, sel.from[2]),
      start_dcol(to_line, sel.to[2]),
      end_dcol(from_line, sel.from[2]),
      end_dcol(to_line, sel.to[2]),
    }
    local d1, d2 = math.min(d[1], d[2]), math.max(d[3], d[4])
    for i, line in ipairs(lines) do
      lines[i] = cut(line, d1, d2)
    end
  end

  local spaces = (" "):rep(vim.bo[snap.buf].tabstop)
  local indent
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("\t", spaces)
    if lines[i]:find("%S") then
      local width = #lines[i]:match("^ *")
      indent = math.min(indent or width, width)
    end
  end
  for i, line in ipairs(lines) do
    lines[i] = line:sub((indent or 0) + 1)
  end
  return lines
end

M.builtin.selection = selected_text

---@param snap sidekick_ultra.Snapshot
---@param ctx table
---@param all boolean
---@return string[]?
local function diagnostics(snap, ctx, all)
  local sel = snap.selection
  local list = vim.tbl_filter(function(d)
    return not sel or d.bufnr ~= snap.buf or (d.lnum + 1 >= sel.from[1] and d.lnum + 1 <= sel.to[1])
  end, vim.diagnostic.get(not all and snap.buf or nil))
  table.sort(list, function(a, b)
    if a.bufnr ~= b.bufnr then
      return a.bufnr < b.bufnr
    end
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)

  local ret = {}
  for _, d in ipairs(list) do
    local r1, c1 = d.lnum + 1, d.col + 1
    local r2 = (d.end_lnum or d.lnum) + 1
    local c2 = d.end_col or c1
    c2 = math.max(c2, r2 == r1 and c1 or 1)
    local loc = { path = snapshot.path(d.bufnr, snap.cwd), kind = "position", r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
    local msg = vim.split(d.message, "\n", { plain = true })
    local head = { ("[%s] %s"):format(vim.diagnostic.severity[d.severity] or "?", msg[1]) }
    for _, extra in ipairs({ d.source, d.code }) do
      if extra and extra ~= "" then
        table.insert(head, tostring(extra))
      end
    end
    table.insert(head, tools.location(loc, ctx.style))
    table.insert(ret, table.concat(head, " "))
    vim.list_extend(ret, msg, 2)
  end
  return #ret > 0 and ret or nil
end

function M.builtin.diagnostics(snap, ctx)
  return diagnostics(snap, ctx, false)
end

function M.builtin.diagnostics_all(snap, ctx)
  return diagnostics(snap, ctx, true)
end

function M.builtin.quickfix(snap, ctx)
  local qf = vim.fn.getqflist({ title = 1, items = 1 })
  if #qf.items == 0 then
    return
  end
  local ret = {}
  if qf.title ~= "" and qf.title:sub(1, 1) ~= ":" then
    table.insert(ret, "Quickfix: " .. qf.title)
  end
  for _, item in ipairs(qf.items) do
    local named = item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr) ~= ""
    local loc = { path = named and snapshot.path(item.bufnr, snap.cwd) or "[No Name]", kind = "file" }
    if item.lnum > 0 then
      loc.kind = "position"
      loc.r1, loc.c1 = item.lnum, math.max(item.col, 1)
      loc.r2, loc.c2 = loc.r1, loc.c1
      if item.end_lnum > 0 then
        loc.r2 = item.end_lnum
        loc.c2 = item.end_col > 0 and item.end_col or loc.c1
        loc.c2 = (loc.r2 == loc.r1) and math.max(loc.c2, loc.c1) or loc.c2
      end
    end
    local msg = vim.split(item.text:gsub("%s+$", ""), "\n", { plain = true })
    local head = { "-", tools.location(loc, ctx.style) }
    if item.type ~= "" then
      table.insert(head, "[" .. item.type:upper() .. "]")
    end
    table.insert(head, msg[1])
    table.insert(ret, (table.concat(head, " "):gsub("%s+$", "")))
    for i = 2, #msg do
      table.insert(ret, "  " .. msg[i])
    end
  end
  return ret
end

---The name of a function or class node: its `name`, `identifier` or `field` child, else the first named child
---whose type mentions "identifier".
---@param node {field: fun(self, name: string): table[], named_child_count: fun(self): integer, named_child: fun(self, i: integer): table, type: fun(self): string}
---@param text_of fun(node: table): string
---@return string?
function M.node_name(node, text_of)
  for _, field in ipairs({ "name", "identifier", "field" }) do
    local child = node:field(field)[1]
    if child then
      return text_of(child)
    end
  end
  for i = 0, node:named_child_count() - 1 do
    local child = node:named_child(i)
    if child:type():find("identifier", 1, true) then
      return text_of(child)
    end
  end
end

---@param word string
---@param name? string
---@param location string
---@return string
function M.describe(word, name, location)
  return name and (word .. " " .. name .. " " .. location) or (word .. " " .. location)
end

---The smallest `<word>.outer` textobject around the cursor (or selection start). Needs a "textobjects" query for
---the buffer's language, which comes from nvim-treesitter-textobjects; without one this yields nothing.
---@param word "function"|"class"
---@return sidekick_ultra.Source
local function textobject(word)
  return function(snap, ctx)
    local ok, node = pcall(function()
      local lang = vim.treesitter.language.get_lang(vim.bo[snap.buf].filetype)
      local query = lang and vim.treesitter.query.get(lang, "textobjects")
      if not query then
        return
      end
      local pos = snap.selection and snap.selection.from or snap.cursor
      local row, col = pos[1] - 1, pos[2] - 1
      local root = vim.treesitter.get_parser(snap.buf, lang):parse()[1]:root()
      local best
      for id, found in query:iter_captures(root, snap.buf, row, row + 1) do
        if query.captures[id] == word .. ".outer" and vim.treesitter.is_in_node_range(found, row, col) then
          -- Captures arrive outer first, so a later containing node is the inner one.
          best = found
        end
      end
      return best
    end)
    if not ok or not node then
      return
    end
    local srow, scol = node:range()
    local name = M.node_name(node, function(n)
      return vim.treesitter.get_node_text(n, snap.buf)
    end)
    local loc = { path = snapshot.path(snap.buf, snap.cwd), kind = "position", r1 = srow + 1, c1 = scol + 1 }
    return { M.describe(word, name, tools.location(loc, ctx.style)) }
  end
end

M.builtin["function"] = textobject("function")
M.builtin.class = textobject("class")

return M
