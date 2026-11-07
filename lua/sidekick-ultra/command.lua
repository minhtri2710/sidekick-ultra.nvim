---`:SidekickUltra <sub> [key=value ...]`: a key=value parser (arguments are never evaluated), dispatch, completion.
local actions = require("sidekick-ultra.actions")
local backends = require("sidekick-ultra.backends")
local errors = require("sidekick-ultra.errors")

local M = {}

local NAME = "SidekickUltra"

---@type table<string, table<string, "string"|"boolean">>
local SUBS = {
  select = { name = "string", focus = "boolean" },
  send = { msg = "string", prompt = "string", name = "string", submit = "boolean", focus = "boolean" },
  prompt = { name = "string", submit = "boolean", focus = "boolean" },
  focus = { name = "string" },
  close = { name = "string", all = "boolean" },
}
local ORDER = { "select", "send", "prompt", "focus", "close" }

---The subcommands that render editor context. With a range they run in the last visual selection, which their
---capture then leaves; the others never enter visual mode.
local SELECTION = { send = true, prompt = true }

---@param id sidekick_ultra.ErrorId
---@param msg string
---@param extra? table
---@return nil
---@return sidekick_ultra.Error
local function fail(id, msg, extra)
  return nil, errors.new(id, msg, extra)
end

---Split `line` into whitespace-separated words. A word may hold double-quoted parts with `\"` and `\\` escapes;
---other backslashes stay as written. Returns the words as `{text, quoted}` or nil and the unterminated word.
---@param line string
---@return { text: string, quoted: boolean }[]?
---@return string? bad
local function words(line)
  local ret, i, n = {}, 1, #line
  while i <= n do
    if line:sub(i, i):find("%s") then
      i = i + 1
    else
      local text, quoted = {}, false
      local start = i
      while i <= n and not line:sub(i, i):find("%s") do
        local ch = line:sub(i, i)
        if ch == '"' and (i == start or line:sub(i - 1, i - 1) == "=") then
          quoted = true
          i = i + 1
          local closed = false
          while i <= n do
            ch = line:sub(i, i)
            if ch == "\\" and (line:sub(i + 1, i + 1) == '"' or line:sub(i + 1, i + 1) == "\\") then
              table.insert(text, line:sub(i + 1, i + 1))
              i = i + 2
            elseif ch == '"' then
              closed = true
              i = i + 1
              break
            else
              table.insert(text, ch)
              i = i + 1
            end
          end
          if not closed then
            return nil, line:sub(start)
          end
          if i <= n and not line:sub(i, i):find("%s") then
            return nil, line:sub(start, i)
          end
        else
          table.insert(text, ch)
          i = i + 1
        end
      end
      table.insert(ret, { text = table.concat(text), quoted = quoted })
    end
  end
  return ret
end

---@param line string the text after `:SidekickUltra`
---@return string? sub
---@return table|sidekick_ultra.Error opts_or_err
function M.parse(line)
  local list, bad = words(line)
  if not list then
    return fail("invalid_args", "unterminated or malformed quoted value: " .. bad, { arg = bad })
  end
  if #list == 0 then
    return fail("incomplete_command", "missing subcommand; use one of: " .. table.concat(ORDER, ", "))
  end
  local sub = list[1].text
  local keys = SUBS[sub]
  if not keys then
    return fail("invalid_command", ("unknown subcommand %q; use one of: %s"):format(sub, table.concat(ORDER, ", ")), {
      sub = sub,
    })
  end
  local opts = {}
  for i = 2, #list do
    local word = list[i].text
    local key, value = word:match("^([%w_]+)=(.*)$")
    if not key or value == "" then
      return fail("invalid_args", "malformed argument " .. word, { arg = word })
    elseif not keys[key] then
      return fail("invalid_args", ("unknown argument %s for %s"):format(key, sub), { arg = key })
    end
    if keys[key] == "boolean" then
      if list[i].quoted or (value ~= "true" and value ~= "false") then
        return fail("invalid_args", key .. " must be true or false", { arg = key })
      end
      opts[key] = value == "true"
    else
      opts[key] = value
    end
  end
  return sub, opts
end

---Run `:SidekickUltra`. `range` is the command's range count; with a range, `SELECTION` subcommands first restore the
---last visual selection so `{selection}` works from `:'<,'>SidekickUltra send ...`.
---@param line string
---@param range? integer
function M.run(line, range)
  local sub, opts = M.parse(line)
  if not sub then
    errors.notify(opts)
    return
  end
  if range and range > 0 and SELECTION[sub] then
    vim.cmd("normal! gv")
  end
  actions[sub](opts)
end

---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
function M.complete(arglead, cmdline, cursorpos)
  local rest = cmdline:sub(1, cursorpos):match(NAME .. "!?%s+(.*)$")
  if not rest then
    return {}
  end
  local list = vim.split(rest, "%s+")
  local ret = {}
  if #list == 1 then
    ret = vim.deepcopy(ORDER)
  elseif SUBS[list[1]] then
    local used = {}
    for i = 2, #list - 1 do
      used[list[i]:match("^([%w_]+)=") or ""] = true
    end
    for key in pairs(SUBS[list[1]]) do
      if not used[key] then
        table.insert(ret, key .. "=")
      end
    end
    table.sort(ret)
  end
  return vim.tbl_filter(function(item)
    return vim.startswith(item, arglead)
  end, ret)
end

function M.setup()
  local desc = "Drive AI CLIs in " .. table.concat(backends.names(), ", ")
  vim.api.nvim_create_user_command(NAME, function(o)
    M.run(o.args, o.range)
  end, { nargs = "*", range = true, complete = M.complete, desc = desc })
end

return M
