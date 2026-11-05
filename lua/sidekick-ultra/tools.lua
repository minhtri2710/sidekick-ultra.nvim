---@class sidekick_ultra.ProcInfo
---@field pid integer
---@field cmd string the backend's best identifier for the foreground program

---@class sidekick_ultra.Tool
---@field name string
---@field cmd string[]
---@field env table<string, string>
---@field url? string
---@field is_proc fun(proc: sidekick_ultra.ProcInfo): boolean
---@field mux_focus boolean send a focus-in sequence before input
---@field location sidekick_ultra.LocationStyle

---@alias sidekick_ultra.LocationStyle "plain"|"claude"|"escaped"

---A structured file location; `tools.location` turns it into sent text.
---@class sidekick_ultra.Location
---@field path string path as shown after `@`
---@field kind "file"|"line"|"position"
---@field r1? integer 1-based first row
---@field c1? integer 1-based first column (position kind)
---@field r2? integer
---@field c2? integer

local M = {}

---@param word string
---@return fun(proc: sidekick_ultra.ProcInfo): boolean
local function word_match(word)
  local re = vim.regex("\\<" .. word .. "\\>")
  return function(proc)
    return re:match_str(proc.cmd) ~= nil
  end
end

---@param spec table
---@return table
local function builtin(spec)
  spec.env = spec.env or {}
  spec.location = spec.location or "plain"
  spec.mux_focus = spec.mux_focus or false
  spec.is_proc = word_match(spec.proc or spec.cmd[1])
  spec.proc = nil
  return spec
end

---@type table<string, table>
local BUILTIN = {
  aider = { cmd = { "aider" }, url = "https://github.com/Aider-AI/aider" },
  amazon_q = { cmd = { "q" }, proc = "qchat", url = "https://github.com/aws/amazon-q-developer-cli" },
  claude = { cmd = { "claude" }, url = "https://github.com/anthropics/claude-code", location = "claude" },
  codex = { cmd = { "codex" }, url = "https://github.com/openai/codex" },
  copilot = { cmd = { "copilot", "--banner" }, url = "https://github.com/github/copilot-cli" },
  crush = { cmd = { "crush" }, url = "https://github.com/charmbracelet/crush" },
  cursor = { cmd = { "cursor-agent" }, url = "https://cursor.com/cli" },
  gemini = { cmd = { "gemini" }, url = "https://github.com/google-gemini/gemini-cli", location = "escaped" },
  grok = { cmd = { "grok" }, url = "https://github.com/superagent-ai/grok-cli" },
  opencode = { cmd = { "opencode" }, url = "https://github.com/sst/opencode", env = { OPENCODE_THEME = "system" } },
  pi = { cmd = { "pi" }, url = "https://github.com/badlogic/pi-mono" },
  qwen = { cmd = { "qwen" }, url = "https://github.com/QwenLM/qwen-code", location = "escaped", mux_focus = true },
}

---@return table<string, sidekick_ultra.Tool>
local function builtins()
  local ret = {}
  for name, spec in pairs(BUILTIN) do
    local tool = builtin(vim.deepcopy(spec))
    tool.name = name
    ret[name] = tool
  end
  -- copilot also runs a language server whose command line contains "copilot".
  local copilot = word_match("copilot")
  ret.copilot.is_proc = function(proc)
    return copilot(proc) and not proc.cmd:find("language-server", 1, true)
  end
  return ret
end

---@type table<string, sidekick_ultra.Tool>
local tools = builtins()

---Names of the built-in tools.
---@return string[]
function M.builtin_names()
  return vim.tbl_keys(BUILTIN)
end

---Rebuild the tool table from the built-ins and the user's `tools` config (already validated).
---A user entry merges field by field over the built-in one (`env` merges key by key); `false` removes a tool.
---@param user? table<string, table|false>
function M.setup(user)
  tools = builtins()
  for name, spec in pairs(user or {}) do
    if spec == false then
      tools[name] = nil
    else
      local tool = tools[name] or { name = name, env = {}, location = "plain", mux_focus = false }
      for key, value in pairs(spec) do
        if key == "env" then
          tool.env = vim.tbl_extend("force", tool.env, value)
        elseif key == "is_proc" and type(value) == "string" then
          local re = vim.regex(value)
          tool.is_proc = function(proc)
            return re:match_str(proc.cmd) ~= nil
          end
        else
          tool[key] = value
        end
      end
      if not tools[name] then
        -- A new tool without `is_proc` matches the basename of its command as a word.
        tool.is_proc = tool.is_proc or word_match(vim.fn.escape(vim.fs.basename(tool.cmd[1]), "\\.*~[]^$/"))
        tools[name] = tool
      end
    end
  end
end

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

---@param tool sidekick_ultra.Tool
---@param proc sidekick_ultra.ProcInfo
---@return boolean
function M.matches(tool, proc)
  return tool.is_proc(proc) == true
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
function M.location(loc, style)
  style = style or "plain"
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

return M
