---The program a command line runs, for the multiplexer backends that only see a command line: a tool installed as a
---node or python script runs as its interpreter (`node /opt/bin/gemini ...`), so the script's name stands for it. Only
---the script word is read. The command line is a local value here and is never returned, stored or logged.
local M = {}

---Flags of node and bun that take a value as the next word.
local NODE_VALUE_FLAGS = {
  ["-r"] = true,
  ["--require"] = true,
  ["--import"] = true,
  ["--loader"] = true,
  ["--experimental-loader"] = true,
  ["-C"] = true,
  ["--conditions"] = true,
}
---Flags of node and bun that run code from the command line: no script.
local NODE_EVAL_FLAGS = { ["-e"] = true, ["--eval"] = true, ["-p"] = true, ["--print"] = true }
---Flags of python that take a value as the next word.
local PYTHON_VALUE_FLAGS = { ["-W"] = true, ["-X"] = true }

---@param program string basename of the program
---@return "node"|"python"? family
local function family(program)
  if program == "node" or program == "nodejs" or program == "bun" then
    return "node"
  end
  -- "Python" is the process name of the macOS framework binary (seen in nvim_get_proc and ps on macOS).
  if program == "python" or program == "python3" or program == "Python" or program:match("^python3%.%d+$") then
    return "python"
  end
end

---Whether `program` (a basename) is an interpreter whose script name stands for the tool.
---@param program string
---@return boolean
function M.is_interpreter(program)
  return family(program) ~= nil
end

---@param token string a script path
---@return string? name basename without one trailing .js, .mjs, .cjs or .py
local function script_name(token)
  local name = vim.fs.basename(token)
  local stem = name:match("^(.+)%.[mc]?js$") or name:match("^(.+)%.py$") or name
  return stem ~= "" and stem or nil
end

---The script word after the flags of a node or bun command line.
---@param words string[] the words after the interpreter
---@return string? name
local function node_script(words)
  local i = 1
  while words[i] do
    local word = words[i]
    if word == "--" then
      return words[i + 1] and script_name(words[i + 1])
    elseif NODE_EVAL_FLAGS[word] then
      return nil
    elseif NODE_VALUE_FLAGS[word] then
      i = i + 2
    elseif word:sub(1, 1) == "-" then
      i = i + 1
    else
      return script_name(word)
    end
  end
end

---The script, or the module of `-m`, after the flags of a python command line.
---@param words string[]
---@return string? name
local function python_script(words)
  local i = 1
  while words[i] do
    local word = words[i]
    -- `-m <module>` needs no branch: -m is skipped as a flag and the module is the first word that is not one.
    if word == "-c" then
      return nil
    elseif PYTHON_VALUE_FLAGS[word] then
      i = i + 2
    elseif word:sub(1, 1) == "-" then
      i = i + 1
    else
      return script_name(word)
    end
  end
end

---What a command line runs: the script name when its first word is an interpreter ("" when it runs no script: an
---eval, `-c`, or none; it is still a program, which matches no tool), else the basename of the first word. nil for an
---empty line.
---ponytail: words are split on whitespace, so a script path with spaces is misread and matches nothing (it fails
---closed); quoting would need a shell-aware parser.
---@param line string
---@return string? name
function M.program(line)
  local words = vim.split(vim.trim(line), "%s+", { trimempty = true })
  if #words == 0 then
    return nil
  end
  local program = vim.fs.basename(words[1])
  local kind = family(program)
  if not kind then
    return program
  end
  local rest = vim.list_slice(words, 2)
  local name
  if kind == "node" then
    name = node_script(rest)
  else
    name = python_script(rest)
  end
  return name or ""
end

return M
