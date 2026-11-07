---@class sidekick_ultra.Config
---@field tools table<string, sidekick_ultra.ToolConfig|false>
---@field prompts table<string, sidekick_ultra.Prompt|false>
---@field context table<string, sidekick_ultra.Source>
---@field watch boolean reload files the agent edits while a session is attached
---@field keys { prefix: string }|false default keymaps under `prefix`, or false for none
---@field [string] any a backend's section (`backends/init.lua` lists the backends and their options)

---A validation failure: `path` is the full key path.
---@class sidekick_ultra.ConfigError
---@field path string
---@field msg string

local backends = require("sidekick-ultra.backends")
local check = require("sidekick-ultra.check")
local keys = require("sidekick-ultra.keys")
local render = require("sidekick-ultra.context.render")
local sources = require("sidekick-ultra.context.sources")
local tools = require("sidekick-ultra.tools")

local M = {}

---The sections that are tables of entries, in the order their errors are reported, each with its owner's check of one
---entry.
---@type { name: string, check: fun(name: string, entry: any): sidekick_ultra.Problem? }[]
local SECTIONS = {
  { name = "tools", check = tools.check },
  { name = "prompts", check = render.check },
  { name = "context", check = sources.check },
}

---@return sidekick_ultra.Config
local function defaults()
  local cfg = {
    watch = true,
    keys = keys.resolve(nil),
  }
  for _, section in ipairs(SECTIONS) do
    cfg[section.name] = {}
  end
  for _, backend in ipairs(backends.all) do
    cfg[backend.name] = { enabled = true }
  end
  return cfg
end

---@param path string
---@param expected string
---@param value any
---@return sidekick_ultra.ConfigError
local function fail(path, expected, value)
  local got = value == nil and "nil" or type(value)
  return { path = path, msg = ("%s: expected %s, got %s"):format(path, expected, got) }
end

---@return sidekick_ultra.ConfigError?
local function check_type(path, value, kind)
  if type(value) ~= kind then
    return fail(path, kind, value)
  end
end

---@param problem sidekick_ultra.Problem
---@return sidekick_ultra.ConfigError
local function from_problem(problem)
  if problem.allowed then
    local names = table.concat(problem.allowed, ", ")
    return { path = problem.path, msg = ("%s: unknown key (allowed: %s)"):format(problem.path, names) }
  end
  return fail(problem.path, problem.expected, problem.got)
end

---Validate user options against the schema and merge them over the defaults.
---@param opts? table
---@return sidekick_ultra.Config? config
---@return sidekick_ultra.ConfigError? err
function M.validate(opts)
  opts = opts or {}
  local cfg = defaults()
  local top = {}
  for section in pairs(cfg) do
    top[section] = true
  end
  local problem = check.table("", opts, top)
  if problem then
    return nil, from_problem(problem)
  end

  local err
  if opts.watch ~= nil then
    err = check_type("watch", opts.watch, "boolean")
    if err then
      return nil, err
    end
    cfg.watch = opts.watch
  end

  local resolved, key_problem = keys.resolve(opts.keys)
  if key_problem then
    return nil, from_problem(key_problem)
  end
  cfg.keys = resolved

  for _, section in ipairs(SECTIONS) do
    local value = opts[section.name]
    if value ~= nil then
      problem = check.table(section.name, value)
      if problem then
        return nil, from_problem(problem)
      end
      cfg[section.name] = vim.deepcopy(value)
    end
  end
  for _, section in ipairs(SECTIONS) do
    for _, name in ipairs(check.sorted_keys(cfg[section.name])) do
      problem = section.check(name, cfg[section.name][name])
      if problem then
        return nil, from_problem(problem)
      end
    end
  end

  for _, backend in ipairs(backends.all) do
    local name, value = backend.name, opts[backend.name]
    if value ~= nil then
      local allowed = {}
      for key in pairs(backends.common) do
        allowed[key] = true
      end
      for key in pairs(backend.options) do
        allowed[key] = true
      end
      problem = check.table(name, value, allowed)
      if problem then
        return nil, from_problem(problem)
      end
      for key, field in pairs(value) do
        local option = backend.options[key] or backends.common[key]
        err = check_type(name .. "." .. key, field, option.type)
        if err then
          return nil, err
        end
        if option.type == "string" and field == "" then
          return nil, fail(name .. "." .. key, "non-empty string", field)
        end
        cfg[name][key] = field
      end
    end
  end
  return cfg
end

---@type sidekick_ultra.Config
local current = defaults()

---Validate and store the configuration. Raises an error naming the key path when it is invalid.
---@param opts? table
---@return sidekick_ultra.Config copy of the stored configuration, see `get()`
function M.setup(opts)
  local cfg, err = M.validate(opts)
  if not cfg then
    error("sidekick-ultra: invalid config: " .. err.msg, 0)
  end
  current = cfg
  return M.get()
end

---The configuration from the last `setup()`, or the defaults before one. Every call returns a fresh deep copy
---(functions stay references), so changing the result never changes the plugin's configuration.
---@return sidekick_ultra.Config
function M.get()
  return vim.deepcopy(current)
end

return M
