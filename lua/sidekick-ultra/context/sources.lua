---The placeholders: one source per name, built in or added by the user's `context` option. A source takes the
---snapshot and returns nothing, a string, or a list of lines; it reads buffers, diagnostics and the quickfix list as
---they are when it runs. A line is a string, or a list of strings and location records (`location.format` writes
---them in the target tool's style when the text is sent).
local location = require("sidekick-ultra.location")

---@alias sidekick_ultra.Line string|(string|sidekick_ultra.Location)[]

---@alias sidekick_ultra.Source fun(snap: sidekick_ultra.Snapshot): string|sidekick_ultra.Line[]?

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
---@param kind "file"|"line"|"position"
---@return sidekick_ultra.Line[]?
local function located(snap, kind)
  if not location.is_file(snap.buf) then
    return
  end
  local loc = { path = location.path(snap.buf, snap.cwd), kind = kind }
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
  return { { loc } }
end

function M.builtin.position(snap)
  return located(snap, "position")
end

function M.builtin.file(snap)
  return located(snap, "file")
end

function M.builtin.line(snap)
  return located(snap, "line")
end

---What `{this}` stands for: `{position}` in a file buffer; elsewhere the word "this", with `{selection}` after the
---whole message. It rewrites the message instead of yielding a value, because the selection goes at the end of it.
---@param snap sidekick_ultra.Snapshot
---@return string replacement
---@return string? tail appended to the message
function M.this(snap)
  if location.is_file(snap.buf) then
    return "{position}"
  end
  return "this", "\n\n{selection}"
end

function M.builtin.buffers(snap)
  local ret = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if location.is_file(buf) then
      local loc = { path = location.path(buf, snap.cwd), kind = "file" }
      table.insert(ret, { "- ", loc })
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
---@param all boolean
---@return sidekick_ultra.Line[]?
local function diagnostics(snap, all)
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
    local loc = location.position(
      location.path(d.bufnr, snap.cwd),
      d.lnum + 1,
      d.col + 1,
      d.end_lnum and d.end_lnum + 1,
      d.end_col
    )
    local msg = vim.split(d.message, "\n", { plain = true })
    local head = { ("[%s] %s"):format(vim.diagnostic.severity[d.severity] or "?", msg[1]) }
    for _, extra in ipairs({ d.source, d.code }) do
      if extra and extra ~= "" then
        table.insert(head, tostring(extra))
      end
    end
    table.insert(ret, { table.concat(head, " ") .. " ", loc })
    vim.list_extend(ret, msg, 2)
  end
  return #ret > 0 and ret or nil
end

function M.builtin.diagnostics(snap)
  return diagnostics(snap, false)
end

function M.builtin.diagnostics_all(snap)
  return diagnostics(snap, true)
end

function M.builtin.quickfix(snap)
  local qf = vim.fn.getqflist({ title = 1, items = 1 })
  if #qf.items == 0 then
    return
  end
  local ret = {}
  if qf.title ~= "" and qf.title:sub(1, 1) ~= ":" then
    table.insert(ret, "Quickfix: " .. qf.title)
  end
  for _, item in ipairs(qf.items) do
    local path = item.bufnr > 0 and location.path(item.bufnr, snap.cwd) or location.NO_NAME
    local loc = { path = path, kind = "file" }
    if item.lnum > 0 then
      local has_end = item.end_lnum > 0
      loc = location.position(
        path,
        item.lnum,
        math.max(item.col, 1),
        has_end and item.end_lnum or nil,
        has_end and item.end_col > 0 and item.end_col or nil
      )
    end
    local msg = vim.split(item.text:gsub("%s+$", ""), "\n", { plain = true })
    local tail = (item.type ~= "" and " [" .. item.type:upper() .. "]" or "") .. " " .. msg[1]
    table.insert(ret, { "- ", loc, (tail:gsub("%s+$", "")) })
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
local function node_name(node, text_of)
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
---@param loc sidekick_ultra.Location
---@return sidekick_ultra.Line
local function describe(word, name, loc)
  return { name and (word .. " " .. name .. " ") or (word .. " "), loc }
end

---The smallest `<word>.outer` textobject around the cursor (or selection start). Needs a "textobjects" query for
---the buffer's language, which comes from nvim-treesitter-textobjects; without one this yields nothing.
---@param word "function"|"class"
---@return sidekick_ultra.Source
local function textobject(word)
  return function(snap)
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
    local name = node_name(node, function(n)
      return vim.treesitter.get_node_text(n, snap.buf)
    end)
    local loc = { path = location.path(snap.buf, snap.cwd), kind = "position", r1 = srow + 1, c1 = scol + 1 }
    return { describe(word, name, loc) }
  end
end

M.builtin["function"] = textobject("function")
M.builtin.class = textobject("class")

return M
