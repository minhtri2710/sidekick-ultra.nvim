---Decides what is sent: renders messages and prompts with `{name}` / `{a|b|c}` placeholders against a snapshot,
---using the sources in `context/sources.lua`. The prompts are checked, stored and shown here too.
local check = require("sidekick-ultra.check")
local errors = require("sidekick-ultra.errors")
local location = require("sidekick-ultra.location")
local sources = require("sidekick-ultra.context.sources")

---@alias sidekick_ultra.Prompt string|{msg: string}|fun(snap: sidekick_ultra.Snapshot): string

local M = {}

---A `{...}` placeholder in a text; the capture is the expression between the braces.
local PLACEHOLDER = "{([^{}]*)}"

---@type table<string, sidekick_ultra.Prompt>
M.default_prompts = {
  changes = "Can you review my changes?",
  diagnostics = "Can you help me fix the diagnostics in {file}?\n{diagnostics}",
  diagnostics_all = "Can you help me fix these diagnostics?\n{diagnostics_all}",
  document = "Add documentation to {function|line}",
  explain = "Explain {this}",
  fix = "Can you fix {this}?",
  optimize = "How can {this} be optimized?",
  review = "Can you review {file} for any issues or improvements?",
  tests = "Can you write tests for {this}?",
}
for name in pairs(sources.builtin) do
  M.default_prompts[name] = M.default_prompts[name] or "{" .. name .. "}"
end

---The first problem in a `prompts` entry, or nil.
---@param name string
---@param prompt any
---@return sidekick_ultra.Problem?
function M.check(name, prompt)
  local path = "prompts." .. name
  if prompt == false or type(prompt) == "string" or type(prompt) == "function" then
    return
  end
  local expected = "string, function, false or table with `msg`"
  if type(prompt) ~= "table" then
    return { path = path, expected = expected, got = prompt }
  end
  if check.table(path, prompt, { msg = true }) then
    return { path = path, expected = expected, got = prompt }
  end
  if type(prompt.msg) ~= "string" then
    return { path = path .. ".msg", expected = "string", got = prompt.msg }
  end
end

---@type table<string, sidekick_ultra.Prompt>
local prompts
---@type table<string, sidekick_ultra.Source>
local active

---Merge the (validated) user config over the defaults; `false` removes a prompt. No arguments resets.
---@param user_prompts? table<string, sidekick_ultra.Prompt|false>
---@param user_context? table<string, sidekick_ultra.Source>
function M.setup(user_prompts, user_context)
  prompts = vim.tbl_extend("force", M.default_prompts, user_prompts or {})
  for name, prompt in pairs(prompts) do
    if prompt == false then
      prompts[name] = nil
    end
  end
  active = vim.tbl_extend("force", sources.builtin, user_context or {})
end

M.setup()

---@return table<string, sidekick_ultra.Prompt>
function M.prompts()
  return prompts
end

---The first line of a raised error, for a message.
---@param cause any
---@return string
local function first_line(cause)
  return vim.split(tostring(cause), "\n", { plain = true })[1]
end

---The prompt's template text, resolved against the snapshot.
---@param name string
---@param snap sidekick_ultra.Snapshot
---@return string? text
---@return sidekick_ultra.Error? err
local function template(name, snap)
  local prompt = prompts[name]
  if prompt == nil then
    return nil, errors.new("unknown_prompt", ("unknown prompt: %s"):format(name))
  elseif type(prompt) == "string" then
    return prompt
  elseif type(prompt) == "table" then
    return prompt.msg
  end
  local ok, text = pcall(prompt, snap)
  if not ok or type(text) ~= "string" then
    local msg = ("prompt %s did not produce text"):format(name)
    return nil, errors.new("render_failed", ok and msg or ("%s: %s"):format(msg, first_line(text)))
  end
  return text
end

---The raw template as the picker shows it.
---@param name string
---@return string
function M.display(name)
  local prompt = prompts[name]
  if type(prompt) == "string" then
    return prompt
  end
  return type(prompt) == "table" and prompt.msg or "<function>"
end

---@param expr string
---@return string[]? names the alternatives, or nil when `expr` is not a placeholder
local function alternatives(expr)
  local names = vim.split(expr, "|", { plain = true })
  for _, name in ipairs(names) do
    if not sources.is_name(name) then
      return
    end
  end
  return names
end

---Whether segments write no text: no location record, and strings that join to "". Two empty lines are "\n", a value.
---@param segments (string|sidekick_ultra.Location)[]
---@return boolean
local function is_empty(segments)
  for _, segment in ipairs(segments) do
    if type(segment) == "table" then
      return false
    end
  end
  return table.concat(segments) == ""
end

---A source's value as flat output segments (lines joined by "\n"), or nil when it yields nothing. Raises when a
---line is not a string or a list of strings and location records.
---@param value any string, or a list of lines
---@return (string|sidekick_ultra.Location)[]?
local function as_segments(value)
  local lines = value
  if type(value) == "string" then
    lines = vim.split(value, "\n", { plain = true })
  elseif type(value) ~= "table" then
    return nil
  end
  local segments = {}
  for i, line in ipairs(lines) do
    if i > 1 then
      table.insert(segments, "\n")
    end
    if type(line) == "string" then
      table.insert(segments, line)
    elseif type(line) == "table" and vim.islist(line) then
      for _, segment in ipairs(line) do
        assert(
          type(segment) == "string" or (type(segment) == "table" and location.is_location(segment)),
          "line segment must be a string or a location record"
        )
        table.insert(segments, segment)
      end
    else
      error("line must be a string or a list of strings and location records")
    end
  end
  return not is_empty(segments) and segments or nil
end

---Render a message and/or a named prompt against a snapshot into output segments: strings and location
---records, written out by `location.format` in the target tool's style. With neither and a selection, the message
---is `{selection}`. Every placeholder is evaluated once, whatever the style. Placeholder values are inserted as-is:
---braces inside them are not expanded again.
---Returns nothing, with no error, when the text is empty: there is nothing to send.
---@param opts {msg?: string, prompt?: string}
---@param snap sidekick_ultra.Snapshot
---@return (string|sidekick_ultra.Location)[]? segments
---@return sidekick_ultra.Error? err
function M.build(opts, snap)
  local parts = {}
  local msg = opts.msg
  if not msg and not opts.prompt and snap.selection then
    msg = "{selection}"
  end
  if msg then
    table.insert(parts, msg)
  end
  if opts.prompt then
    local text, err = template(opts.prompt, snap)
    if not text then
      return nil, err
    end
    table.insert(parts, text)
  end
  local text = table.concat(parts, "\n")

  if text:find("{this}", 1, true) then
    local replacement, tail = sources.this(snap)
    text = text:gsub("{this}", replacement) .. (tail or "")
  end

  local exprs, unknown, seen = {}, {}, {}
  for expr in text:gmatch(PLACEHOLDER) do
    local names = alternatives(expr)
    if names and not seen[expr] then
      seen[expr] = true
      table.insert(exprs, { expr = expr, names = names })
      for _, name in ipairs(names) do
        if not active[name] and not vim.tbl_contains(unknown, name) then
          table.insert(unknown, name)
        end
      end
    end
  end
  if #unknown > 0 then
    return nil, errors.new("unknown_context", "unknown context: " .. table.concat(unknown, ", "))
  end

  local memo, causes = {}, {}
  local function value(name)
    if memo[name] == nil then
      local ok, ret = pcall(function()
        return as_segments(active[name](snap))
      end)
      if not ok then
        table.insert(causes, ("%s: %s"):format(name, first_line(ret)))
      end
      memo[name] = ok and ret or false
    end
    return memo[name]
  end

  local resolved, failed = {}, {}
  for _, e in ipairs(exprs) do
    for _, name in ipairs(e.names) do
      resolved[e.expr] = value(name)
      if resolved[e.expr] then
        break
      end
    end
    if not resolved[e.expr] then
      table.insert(failed, e.expr)
    end
  end
  if #failed > 0 then
    local head = "nothing to render for: " .. table.concat(failed, ", ")
    if #causes > 0 then
      head = ("%s (%s)"):format(head, table.concat(causes, "; "))
    end
    return nil, errors.new("render_failed", head)
  end

  local out, pos = {}, 1
  while true do
    local first, last, expr = text:find(PLACEHOLDER, pos)
    if not first then
      break
    end
    table.insert(out, text:sub(pos, first - 1))
    if resolved[expr] then
      vim.list_extend(out, resolved[expr])
    else
      table.insert(out, text:sub(first, last))
    end
    pos = last + 1
  end
  table.insert(out, text:sub(pos))
  return not is_empty(out) and out or nil
end

return M
