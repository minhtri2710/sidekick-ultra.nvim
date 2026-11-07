---@class sidekick_ultra.ToolConfig
---@field cmd? string[] non-empty; required for a tool that is not built in
---@field env? table<string, string>
---@field url? string
---@field is_proc? string|fun(proc: sidekick_ultra.ProcInfo): boolean Vim regex or predicate
---@field mux_focus? boolean
---@field location? sidekick_ultra.LocationStyle

---@alias sidekick_ultra.PromptConfig string|{ msg: string }|fun(snap: sidekick_ultra.Snapshot): string

---@class sidekick_ultra.Config
---@field tools table<string, sidekick_ultra.ToolConfig|false>
---@field prompts table<string, sidekick_ultra.PromptConfig|false>
---@field context table<string, fun(snap: sidekick_ultra.Snapshot): string|string[]|nil>
---@field watch boolean reload files the agent edits while a session is attached
---@field keys { prefix: string }|false default keymaps under `prefix`, or false for none
---@field herdr { enabled: boolean }
---@field rex { enabled: boolean, bin?: string, server?: string } `bin` and `server` are passed to the rex backend as is
---@field tmux { enabled: boolean, socket?: string } `socket` becomes `-S <socket>` on every tmux call
---@field zellij { enabled: boolean }

---A validation failure: `path` is the full key path, `expected` the type or values wanted.
---@class sidekick_ultra.ConfigError
---@field path string
---@field expected string
---@field msg string

local backends = require("sidekick-ultra.backends")
local keys = require("sidekick-ultra.keys")

local M = {}

---@return sidekick_ultra.Config
local function defaults()
  local cfg = {
    tools = {},
    prompts = {},
    context = {},
    watch = true,
    keys = keys.resolve(nil),
  }
  for _, backend in ipairs(backends.all) do
    cfg[backend.name] = { enabled = true }
  end
  return cfg
end

local LOCATIONS = { "plain", "claude", "escaped" }

---@param path string
---@param expected string
---@param value any
---@return sidekick_ultra.ConfigError
local function fail(path, expected, value)
  local got = value == nil and "nil" or type(value)
  return { path = path, expected = expected, msg = ("%s: expected %s, got %s"):format(path, expected, got) }
end

---@param t table
---@return string[]
local function sorted_keys(t)
  local names = vim.tbl_keys(t)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return names
end

---@param path string
---@param allowed string[] sorted
---@return sidekick_ultra.ConfigError
local function unknown_key(path, allowed)
  local names = table.concat(allowed, ", ")
  return { path = path, expected = "one of: " .. names, msg = ("%s: unknown key (allowed: %s)"):format(path, names) }
end

---Check that `value` is a table whose keys are all in `allowed` (a set); an `allowed` of nil allows any string key.
---@return sidekick_ultra.ConfigError?
local function check_table(path, value, allowed)
  if type(value) ~= "table" then
    return fail(path == "" and "opts" or path, "table", value)
  end
  for _, key in ipairs(sorted_keys(value)) do
    local full = path == "" and tostring(key) or (path .. "." .. tostring(key))
    if type(key) ~= "string" then
      return fail(full, "string key", key)
    elseif allowed and not allowed[key] then
      return unknown_key(full, sorted_keys(allowed))
    end
  end
end

local function set(...)
  local ret = {}
  for _, key in ipairs({ ... }) do
    ret[key] = true
  end
  return ret
end

---@return sidekick_ultra.ConfigError?
local function check_type(path, value, kind)
  if type(value) ~= kind then
    return fail(path, kind, value)
  end
end

---@return sidekick_ultra.ConfigError?
local function check_tool(name, tool, is_builtin)
  local path = "tools." .. name
  if tool == false then
    return
  end
  local err = check_table(path, tool, set("cmd", "env", "url", "is_proc", "mux_focus", "location"))
  if err then
    return err
  end
  if tool.cmd == nil then
    if not is_builtin then
      return fail(path .. ".cmd", "non-empty list of strings (required for a new tool)", nil)
    end
  elseif not vim.islist(tool.cmd) or #tool.cmd == 0 then
    return fail(path .. ".cmd", "non-empty list of strings", tool.cmd)
  else
    for i, arg in ipairs(tool.cmd) do
      if type(arg) ~= "string" or (i == 1 and arg == "") then
        return fail(("%s.cmd[%d]"):format(path, i), "string", arg)
      end
    end
  end
  if tool.env ~= nil then
    err = check_table(path .. ".env", tool.env)
    if err then
      return err
    end
    for key, value in pairs(tool.env) do
      if type(value) ~= "string" then
        return fail(path .. ".env." .. key, "string", value)
      end
    end
  end
  if tool.url ~= nil and type(tool.url) ~= "string" then
    return fail(path .. ".url", "string", tool.url)
  end
  if tool.mux_focus ~= nil and type(tool.mux_focus) ~= "boolean" then
    return fail(path .. ".mux_focus", "boolean", tool.mux_focus)
  end
  if tool.location ~= nil and not vim.tbl_contains(LOCATIONS, tool.location) then
    return fail(path .. ".location", "one of: " .. table.concat(LOCATIONS, ", "), tool.location)
  end
  local is_proc = tool.is_proc
  if type(is_proc) == "string" then
    if not pcall(vim.regex, is_proc) then
      return fail(path .. ".is_proc", "valid Vim regex", is_proc)
    end
  elseif is_proc ~= nil and type(is_proc) ~= "function" then
    return fail(path .. ".is_proc", "Vim regex string or function", is_proc)
  end
end

---@return sidekick_ultra.ConfigError?
local function check_prompt(name, prompt)
  local path = "prompts." .. name
  if prompt == false or type(prompt) == "string" or type(prompt) == "function" then
    return
  end
  local err = check_table(path, prompt, set("msg"))
  if err then
    return fail(path, "string, function, false or table with `msg`", prompt)
  end
  return check_type(path .. ".msg", prompt.msg, "string")
end

---Validate user options against the schema and merge them over the defaults.
---@param opts? table
---@return sidekick_ultra.Config? config
---@return sidekick_ultra.ConfigError? err
function M.validate(opts)
  opts = opts or {}
  local cfg = defaults()
  local top = set("tools", "prompts", "context", "watch", "keys")
  for _, backend in ipairs(backends.all) do
    top[backend.name] = true
  end
  local err = check_table("", opts, top)
  if err then
    return nil, err
  end

  if opts.watch ~= nil then
    err = check_type("watch", opts.watch, "boolean")
    if err then
      return nil, err
    end
    cfg.watch = opts.watch
  end

  local resolved, problem = keys.resolve(opts.keys)
  if not resolved and problem then
    if problem.allowed then
      return nil, unknown_key(problem.path, problem.allowed)
    end
    return nil, fail(problem.path, problem.expected, problem.got)
  end
  cfg.keys = resolved

  for _, section in ipairs({ "tools", "prompts", "context" }) do
    local value = opts[section]
    if value ~= nil then
      err = check_table(section, value)
      if err then
        return nil, err
      end
      cfg[section] = vim.deepcopy(value)
    end
  end
  local builtin = set(unpack(require("sidekick-ultra.tools").builtin_names()))
  for _, name in ipairs(sorted_keys(cfg.tools)) do
    err = check_tool(name, cfg.tools[name], builtin[name])
    if err then
      return nil, err
    end
  end
  for _, name in ipairs(sorted_keys(cfg.prompts)) do
    err = check_prompt(name, cfg.prompts[name])
    if err then
      return nil, err
    end
  end
  for _, name in ipairs(sorted_keys(cfg.context)) do
    err = check_type("context." .. name, cfg.context[name], "function")
    if err then
      return nil, err
    end
  end

  for _, backend in ipairs(backends.all) do
    local name, value = backend.name, opts[backend.name]
    if value ~= nil then
      local allowed = set("enabled")
      for key in pairs(backend.options) do
        allowed[key] = true
      end
      err = check_table(name, value, allowed)
      if err then
        return nil, err
      end
      for key, field in pairs(value) do
        local option = backend.options[key]
        err = check_type(name .. "." .. key, field, option and option.type or "boolean")
        if err then
          return nil, err
        end
        if option and option.non_empty and field == "" then
          return nil, fail(name .. "." .. key, "non-empty " .. option.type, field)
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
