---Shared by the backend specs: the fixture reader, the `exec.run` recorder and the secret every leak check looks for.
local exec = require("sidekick-ultra.exec")

local M = {}

---A value that must never reach a session, an error, a toast or a recorded call. Fixtures carry it as `@SECRET@`.
M.SECRET = "SECRET-TOKEN-xyz"

---Command lines that carry SECRET, with the tool each one runs. Every row is a `node` or `python3` interpreter line, so
---the interpreter's own name is its first word.
---@type { [1]: string, [2]: string? }[]
M.SECRET_LINES = {
  { "node /x/bin/gemini --api-key " .. M.SECRET, "gemini" },
  { "node --require " .. M.SECRET .. " /x/bin/gemini", "gemini" },
  { 'node -e "' .. M.SECRET .. '"', nil },
  { "python3 -m aider --token " .. M.SECRET, "aider" },
  { 'python3 -c "' .. M.SECRET .. '"', nil },
  { 'node -pe "/x/' .. M.SECRET .. '/gemini"', nil },
  { 'node -ep "/x/' .. M.SECRET .. '/gemini"', nil },
  { "node --eval=0 /x/" .. M.SECRET .. "/gemini", nil },
  { "node --print=0 /x/" .. M.SECRET .. "/gemini", nil },
  { "node --run /x/" .. M.SECRET .. "/gemini", nil },
  { "node --env-file " .. M.SECRET .. " /x/bin/gemini", "gemini" },
  { "node --title " .. M.SECRET .. " /x/bin/gemini", "gemini" },
  { "node --config-file /x/bin/qwen --x /x/" .. M.SECRET .. "/gemini", "qwen" },
  { "node - /x/" .. M.SECRET .. "/gemini", nil },
  { 'python3 -uc "/x/' .. M.SECRET .. '/gemini"', nil },
  { "python3 -c/x/" .. M.SECRET .. "/gemini", nil },
  { "python3 -Wc /x/bin/aider --token " .. M.SECRET, nil },
  { "python3 -maider /x/" .. M.SECRET .. "/gemini", nil },
  { "python3 -uX /x/" .. M.SECRET .. "/gemini /x/bin/aider", "aider" },
  { "python3 --check-hash-based-pycs " .. M.SECRET .. " /x/bin/aider", "aider" },
  { "python3 - /x/" .. M.SECRET .. "/gemini", nil },
}

local FIXTURES = vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))) .. "/fixtures/"

---A reader for tests/fixtures/<dir>. It gives the file byte for byte, with `@SECRET@` replaced by SECRET.
---@param dir string
---@param ext? string appended to every name
---@return fun(name: string): string
function M.fixtures(dir, ext)
  return function(name)
    -- Binary mode: a final NL becomes a last empty item, so joining with NL gives the file back byte for byte.
    local text = table.concat(vim.fn.readfile(FIXTURES .. dir .. "/" .. name .. (ext or ""), "b"), "\n")
    return (text:gsub("@SECRET@", M.SECRET))
  end
end

---@param stdout string
---@return { code: integer, stdout: string, stderr: string }
function M.ok(stdout)
  return { code = 0, stdout = stdout, stderr = "" }
end

---@class sidekick_ultra.spec.Recorder
---@field calls { argv: string[], opts: table }[] every call, in order
---@field subs string[][] the second value of `route_key` for every call (the key as a one-element list if it gave none)
---@field keys string[] the route key of every call
---@field unexpected string[] the keys of the calls that had no route
---@field argvs fun(): string[][]
---@field restore fun() puts `exec.run` back and asserts that no call was unexpected

---Replace `exec.run`. `routes` maps a call's key to its answer: stdout text, a `{code, stdout, stderr}` result,
---`{run_error = <Error>}` (exec could not run it), or a function(call number of this key, argv) returning one of
---those. A call without a route is recorded in `unexpected` and answers exit 97; `restore` fails the case then.
---@param routes table<string, string|table|fun(n: integer, argv: string[]): string|table>
---@param route_key fun(argv: string[]): string, string[]? the key of a call, and optionally its subcommand words
---@return sidekick_ultra.spec.Recorder
function M.record(routes, route_key)
  local rec = { calls = {}, subs = {}, keys = {}, unexpected = {} }
  local orig = exec.run
  local counts = {}
  exec.run = function(argv, opts)
    table.insert(rec.calls, { argv = vim.deepcopy(argv), opts = opts })
    local key, sub = route_key(argv)
    table.insert(rec.keys, key)
    table.insert(rec.subs, sub or { key })
    counts[key] = (counts[key] or 0) + 1
    local route = routes[key]
    if type(route) == "function" then
      route = route(counts[key], argv)
    end
    if route == nil then
      table.insert(rec.unexpected, key)
      return { code = 97, stdout = "", stderr = "unexpected command" }
    end
    if type(route) == "string" then
      return M.ok(route)
    end
    if route.run_error then
      return nil, route.run_error
    end
    return route
  end
  function rec.argvs()
    return vim.tbl_map(function(call)
      return call.argv
    end, rec.calls)
  end
  function rec.restore()
    exec.run = orig
    MiniTest.expect.equality(rec.unexpected, {})
  end
  return rec
end

return M
