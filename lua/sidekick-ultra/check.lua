---The table check shared by `config`, `tools` and `render`, and the problem record it returns.

---A problem found while validating the options: `path` is the full key path. A key that is not allowed has `allowed`
---(the allowed keys, sorted); any other problem has `expected` and the offending `got`. `config` turns it into the
---message.
---@class sidekick_ultra.Problem
---@field path string
---@field expected? string
---@field got? any
---@field allowed? string[]

local M = {}

---@param t table
---@return string[]
function M.sorted_keys(t)
  local names = vim.tbl_keys(t)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return names
end

---The first problem in a table, in key order: `value` is not a table, a key is not a string, or a key is not in
---`allowed` (a set; nil allows any string key). A `path` of "" is the top-level options.
---@param path string
---@param value any
---@param allowed? table<string, true>
---@return sidekick_ultra.Problem?
function M.table(path, value, allowed)
  if type(value) ~= "table" then
    return { path = path == "" and "opts" or path, expected = "table", got = value }
  end
  for _, key in ipairs(M.sorted_keys(value)) do
    local full = path == "" and tostring(key) or (path .. "." .. tostring(key))
    if type(key) ~= "string" then
      return { path = full, expected = "string key", got = key }
    elseif allowed and not allowed[key] then
      return { path = full, allowed = M.sorted_keys(allowed) }
    end
  end
end

return M
