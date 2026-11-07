---The tools the plugin can drive: the built-in specs, the user's `tools` config merged over them, the validation of
---that config, and how a tool is recognised among running processes.
local location = require("sidekick-ultra.location")

---What `is_proc` is asked about; proc.lua builds it and defines `cmd`.
---@class sidekick_ultra.ProcInfo
---@field pid? integer absent only for zellij, which reports none
---@field cmd string one program name

---@class sidekick_ultra.ToolConfig
---@field cmd? string[] non-empty; required for a tool that is not built in
---@field env? table<string, string>
---@field url? string
---@field is_proc? string|fun(proc: sidekick_ultra.ProcInfo): boolean Vim regex or predicate; default: the basename of `cmd[1]` as a word
---@field mux_focus? boolean send a focus-in sequence before input
---@field location? sidekick_ultra.LocationStyle

---@class sidekick_ultra.Tool
---@field name string
---@field cmd string[]
---@field env table<string, string>
---@field url? string
---@field is_proc fun(proc: sidekick_ultra.ProcInfo): boolean
---@field mux_focus boolean
---@field location sidekick_ultra.LocationStyle

local M = {}

---@param re string Vim regex
---@return fun(proc: sidekick_ultra.ProcInfo): boolean
local function matcher(re)
  local compiled = vim.regex(re)
  return function(proc)
    return compiled:match_str(proc.cmd) ~= nil
  end
end

---@param program string
---@return fun(proc: sidekick_ultra.ProcInfo): boolean
local function word(program)
  return matcher("\\<" .. vim.fn.escape(program, "\\.*~[]^$/") .. "\\>")
end

local copilot = word("copilot")

---@type table<string, sidekick_ultra.ToolConfig>
local BUILTIN = {
  aider = { cmd = { "aider" }, url = "https://github.com/Aider-AI/aider" },
  -- Installed as `q`, runs as `qchat`.
  amazon_q = { cmd = { "q" }, is_proc = "\\<qchat\\>", url = "https://github.com/aws/amazon-q-developer-cli" },
  claude = { cmd = { "claude" }, url = "https://github.com/anthropics/claude-code", location = "claude" },
  codex = { cmd = { "codex" }, url = "https://github.com/openai/codex" },
  copilot = {
    cmd = { "copilot", "--banner" },
    url = "https://github.com/github/copilot-cli",
    -- It also runs a language server whose command line contains "copilot".
    is_proc = function(proc)
      return copilot(proc) and not proc.cmd:find("language-server", 1, true)
    end,
  },
  crush = { cmd = { "crush" }, url = "https://github.com/charmbracelet/crush" },
  cursor = { cmd = { "cursor-agent" }, url = "https://cursor.com/cli" },
  gemini = { cmd = { "gemini" }, url = "https://github.com/google-gemini/gemini-cli", location = "escaped" },
  grok = { cmd = { "grok" }, url = "https://github.com/superagent-ai/grok-cli" },
  opencode = { cmd = { "opencode" }, url = "https://github.com/sst/opencode", env = { OPENCODE_THEME = "system" } },
  pi = { cmd = { "pi" }, url = "https://github.com/badlogic/pi-mono" },
  qwen = { cmd = { "qwen" }, url = "https://github.com/QwenLM/qwen-code", location = "escaped", mux_focus = true },
}

---@type string[] sorted
local FIELDS = { "cmd", "env", "is_proc", "location", "mux_focus", "url" }
local ALLOWED = {}
for _, field in ipairs(FIELDS) do
  ALLOWED[field] = true
end

---The first problem in a `tools` entry, or nil. `path` is the full key path. A key that is not allowed has `allowed`
---(the allowed keys); any other problem has `expected` and the offending `got`.
---@param path string
---@param value any
---@param allowed? table<string, true> nil allows any string key
---@return sidekick_ultra.Problem?
local function check_map(path, value, allowed)
  if type(value) ~= "table" then
    return { path = path, expected = "table", got = value }
  end
  local names = vim.tbl_keys(value)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(names) do
    if type(key) ~= "string" then
      return { path = path .. "." .. tostring(key), expected = "string key", got = key }
    elseif allowed and not allowed[key] then
      return { path = path .. "." .. key, allowed = FIELDS }
    end
  end
end

---Check one entry of the user's `tools` option: `false` removes a tool, a table is merged over the built-in of that
---name or defines a new tool, which needs a `cmd`.
---@param name string
---@param spec any
---@return sidekick_ultra.Problem?
function M.check(name, spec)
  if spec == false then
    return
  end
  local path = "tools." .. name
  local problem = check_map(path, spec, ALLOWED)
  if problem then
    return problem
  end
  if spec.cmd == nil then
    if not BUILTIN[name] then
      return { path = path .. ".cmd", expected = "non-empty list of strings (required for a new tool)" }
    end
  elseif not vim.islist(spec.cmd) or #spec.cmd == 0 then
    return { path = path .. ".cmd", expected = "non-empty list of strings", got = spec.cmd }
  else
    for i, arg in ipairs(spec.cmd) do
      if type(arg) ~= "string" or (i == 1 and arg == "") then
        return { path = ("%s.cmd[%d]"):format(path, i), expected = "string", got = arg }
      end
    end
  end
  if spec.env ~= nil then
    problem = check_map(path .. ".env", spec.env)
    if problem then
      return problem
    end
    for key, value in pairs(spec.env) do
      if type(value) ~= "string" then
        return { path = path .. ".env." .. key, expected = "string", got = value }
      end
    end
  end
  if spec.url ~= nil and type(spec.url) ~= "string" then
    return { path = path .. ".url", expected = "string", got = spec.url }
  end
  if spec.mux_focus ~= nil and type(spec.mux_focus) ~= "boolean" then
    return { path = path .. ".mux_focus", expected = "boolean", got = spec.mux_focus }
  end
  if spec.location ~= nil and not vim.tbl_contains(location.styles, spec.location) then
    return {
      path = path .. ".location",
      expected = "one of: " .. table.concat(location.styles, ", "),
      got = spec.location,
    }
  end
  local is_proc = spec.is_proc
  if type(is_proc) == "string" then
    if not pcall(vim.regex, is_proc) then
      return { path = path .. ".is_proc", expected = "valid Vim regex", got = is_proc }
    end
  elseif is_proc ~= nil and type(is_proc) ~= "function" then
    return { path = path .. ".is_proc", expected = "Vim regex string or function", got = is_proc }
  end
end

---Fill in a tool's defaults. A tool without `is_proc` matches the basename of its `cmd[1]` as a word. The default is
---fixed when the tool is first defined, so a user's `cmd` for a built-in changes how it starts, not what it is
---recognised by.
---@param name string
---@param spec table fields of a `sidekick_ultra.ToolConfig`; `is_proc` may be a function already
---@return sidekick_ultra.Tool
local function build(name, spec)
  local is_proc = spec.is_proc
  if type(is_proc) == "string" then
    is_proc = matcher(is_proc)
  elseif is_proc == nil then
    is_proc = word(vim.fs.basename(spec.cmd[1]))
  end
  return {
    name = name,
    cmd = spec.cmd,
    env = spec.env or {},
    url = spec.url,
    is_proc = is_proc,
    mux_focus = spec.mux_focus or false,
    location = spec.location or location.DEFAULT_STYLE,
  }
end

---@type table<string, sidekick_ultra.Tool>
local builtin = {}
for name, spec in pairs(BUILTIN) do
  builtin[name] = build(name, spec)
end

---@type table<string, sidekick_ultra.Tool>
local tools = {}

---Rebuild the tool table from the built-ins and the user's `tools` config (already checked). A user entry merges
---field by field over the built-in one (`env` merges key by key); `false` removes a tool.
---@param user? table<string, sidekick_ultra.ToolConfig|false>
function M.setup(user)
  tools = vim.deepcopy(builtin)
  for name, spec in pairs(user or {}) do
    if spec == false then
      tools[name] = nil
    else
      local base = tools[name] or {}
      local vars = vim.tbl_extend("force", base.env or {}, spec.env or {})
      tools[name] = build(name, vim.tbl_extend("force", base, spec, { env = vars }))
    end
  end
end

M.setup()

---@param name string
---@return sidekick_ultra.Tool?
function M.get(name)
  return tools[name]
end

---@return table<string, sidekick_ultra.Tool>
function M.all()
  return tools
end

---Configured tools, sorted by name.
---@return sidekick_ultra.Tool[]
function M.list()
  local ret = vim.tbl_values(tools)
  table.sort(ret, function(a, b)
    return a.name < b.name
  end)
  return ret
end

---@param tool sidekick_ultra.Tool
---@return boolean
function M.installed(tool)
  return vim.fn.executable(tool.cmd[1]) == 1
end

return M
