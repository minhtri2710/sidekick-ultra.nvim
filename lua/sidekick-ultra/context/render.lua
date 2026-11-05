---Template rendering: messages and prompts with `{name}` / `{a|b|c}` placeholders. Pure over a snapshot.
local errors = require("sidekick-ultra.errors")
local snapshot = require("sidekick-ultra.context.snapshot")
local sources = require("sidekick-ultra.context.sources")

---@alias sidekick_ultra.Prompt string|{msg: string}|fun(snap: sidekick_ultra.Snapshot): string

local M = {}

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
for _, name in ipairs({ "buffers", "file", "line", "position", "quickfix", "selection", "function", "class" }) do
  M.default_prompts[name] = "{" .. name .. "}"
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

---The prompt's template text, resolved against the snapshot.
---@param name string
---@param snap sidekick_ultra.Snapshot
---@return string? text
---@return sidekick_ultra.Error? err
function M.template(name, snap)
  local prompt = prompts[name]
  if prompt == nil then
    return nil, errors.new("unknown_prompt", ("unknown prompt: %s"):format(name), { names = { name } })
  elseif type(prompt) == "string" then
    return prompt
  elseif type(prompt) == "table" then
    return prompt.msg
  end
  local ok, text = pcall(prompt, snap)
  if not ok or type(text) ~= "string" then
    return nil,
      errors.new("render_failed", ("prompt %s did not produce text"):format(name), {
        names = { name },
        detail = not ok and tostring(text) or nil,
      })
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
    if not name:match("^[%w_]+$") then
      return
    end
  end
  return names
end

---@param value any
---@return string[]?
local function as_lines(value)
  if type(value) == "string" then
    return vim.split(value, "\n", { plain = true })
  end
  return type(value) == "table" and value or nil
end

---@param lines string[]?
---@return boolean
local function empty(lines)
  return lines == nil or table.concat(lines, "\n") == ""
end

---Render a message and/or a named prompt against a snapshot. Returns "" when there is nothing to render.
---Placeholder values are inserted as-is: braces inside them are not expanded again.
---@param opts {msg?: string, prompt?: string}
---@param snap sidekick_ultra.Snapshot
---@param style? sidekick_ultra.LocationStyle
---@return string? text
---@return sidekick_ultra.Error? err
function M.render(opts, snap, style)
  local parts = {}
  if opts.msg then
    table.insert(parts, opts.msg)
  end
  if opts.prompt then
    local text, err = M.template(opts.prompt, snap)
    if not text then
      return nil, err
    end
    table.insert(parts, text)
  end
  local text = table.concat(parts, "\n")

  if text:find("{this}", 1, true) then
    if snapshot.is_file(snap.buf) then
      text = text:gsub("{this}", "{position}")
    else
      text = text:gsub("{this}", "this") .. "\n\n{selection}"
    end
  end

  local exprs, unknown, seen = {}, {}, {}
  for expr in text:gmatch("{([^{}]*)}") do
    local names = alternatives(expr)
    if names and not seen[expr] then
      seen[expr] = true
      table.insert(exprs, expr)
      for _, name in ipairs(names) do
        if not active[name] and not vim.tbl_contains(unknown, name) then
          table.insert(unknown, name)
        end
      end
    end
  end
  if #unknown > 0 then
    return nil, errors.new("unknown_context", "unknown context: " .. table.concat(unknown, ", "), { names = unknown })
  end

  local memo, details = {}, {}
  local function value(name)
    if memo[name] == nil then
      local ok, ret = pcall(active[name], snap, { style = style })
      if not ok then
        table.insert(details, ("%s: %s"):format(name, tostring(ret)))
      end
      local lines = ok and as_lines(ret) or nil
      memo[name] = not empty(lines) and table.concat(lines, "\n")
    end
    return memo[name]
  end

  local resolved, failed = {}, {}
  for _, expr in ipairs(exprs) do
    for _, name in ipairs(alternatives(expr) or {}) do
      resolved[expr] = value(name)
      if resolved[expr] then
        break
      end
    end
    if not resolved[expr] then
      table.insert(failed, expr)
    end
  end
  if #failed > 0 then
    return nil,
      errors.new("render_failed", "nothing to render for: " .. table.concat(failed, ", "), {
        names = failed,
        detail = #details > 0 and table.concat(details, "; ") or nil,
      })
  end

  return (text:gsub("{([^{}]*)}", function(expr)
    return resolved[expr]
  end))
end

return M
