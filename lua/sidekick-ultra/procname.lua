---The program a command line runs, for the backends that only see a command line or a process name: a tool installed as a
---node or python script runs as its interpreter (`node /opt/bin/gemini ...`), so the script's name stands for it. Only
---the script word is read. The command line is a local value here and is never returned, stored or logged.
local errors = require("sidekick-ultra.errors")
local exec = require("sidekick-ultra.exec")

local M = {}

---@param list string[]
---@return table<string, true>
local function set(list)
  local out = {}
  for _, item in ipairs(list) do
    out[item] = true
  end
  return out
end

---Flags of node that take a value as the next word: the options `node --help` (v26.13.0) lists with a `=...` or
---`=[host:]port` value (`--title=...`, `-r, --require=...`), each probed on node v26.13.0 itself: `node <flag>
---zz-none-probe.js` consumed the word (per-flag table: reviews/d10-help/node-probe.txt). The help line
---`--experimental-config-file, --experimental-default-config-file, --config-file=...` is wrong: those three take no
---separate value (the next word is the script), so they are not here. bun shares the table (unverified). `--run` is not
---here: it runs a package.json task and takes no script (NODE_EVAL_FLAGS).
local NODE_VALUE_FLAGS = set({
  "-C",
  "-r",
  "--allow-fs-read",
  "--allow-fs-write",
  "--bench-isolation",
  "--bench-name-pattern",
  "--bench-reporter",
  "--bench-reporter-destination",
  "--bench-samples",
  "--bench-warmup",
  "--build-sea",
  "--build-snapshot-config",
  "--conditions",
  "--cpu-prof-dir",
  "--cpu-prof-interval",
  "--cpu-prof-name",
  "--debug-port",
  "--diagnostic-dir",
  "--disable-proto",
  "--disable-warning",
  "--dns-result-order",
  "--env-file",
  "--env-file-if-exists",
  "--experimental-loader",
  "--experimental-package-map",
  "--experimental-sea-config",
  "--experimental-test-isolation",
  "--experimental-test-tag-filter",
  "--heap-prof-dir",
  "--heap-prof-interval",
  "--heap-prof-name",
  "--heapsnapshot-near-heap-limit",
  "--heapsnapshot-signal",
  "--icu-data-dir",
  "--import",
  "--input-type",
  "--inspect-port",
  "--inspect-publish-uid",
  "--loader",
  "--localstorage-file",
  "--max-http-header-size",
  "--max-old-space-size-percentage",
  "--network-family-autoselection-attempt-timeout",
  "--openssl-config",
  "--process-timeout",
  "--redirect-warnings",
  "--report-dir",
  "--report-directory",
  "--report-filename",
  "--report-signal",
  "--require",
  "--secure-heap",
  "--secure-heap-min",
  "--snapshot-blob",
  "--test-concurrency",
  "--test-coverage-branches",
  "--test-coverage-exclude",
  "--test-coverage-functions",
  "--test-coverage-include",
  "--test-coverage-lines",
  "--test-global-setup",
  "--test-isolation",
  "--test-name-pattern",
  "--test-random-seed",
  "--test-reporter",
  "--test-reporter-destination",
  "--test-rerun-failures",
  "--test-shard",
  "--test-skip-pattern",
  "--test-timeout",
  "--title",
  "--tls-cipher-list",
  "--tls-keylog",
  "--trace-event-categories",
  "--trace-event-file-pattern",
  "--trace-require-module",
  "--unhandled-rejections",
  "--use-largepages",
  "--v8-pool-size",
  "--vfs-load",
  "--watch-kill-signal",
  "--watch-path",
})
---Flags of node and bun that run code from the command line, a package.json task, or stdin (a lone `-`): no script.
---`--eval=...`, `--print=...` and `--run=...` are eval too (node_eval).
local NODE_EVAL_FLAGS = set({ "-e", "--eval", "-p", "--print", "--run", "-" })
---Flags of python that take a value as the next word: `-W arg`, `-X opt` and `--check-hash-based-pycs always|default|never`
---in `python3 --help` (3.9.6).
local PYTHON_VALUE_FLAGS = set({ "-W", "-X", "--check-hash-based-pycs" })

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

---A short-flag cluster: one dash, then two or more letters (`-pe`, `-uc`, `-Wignore`). Neither `node --help` nor
---`python3 --help` says how a cluster is split, so each rule below reads the whole word and fails closed.
---@param word string
---@return boolean
local function is_cluster(word)
  return #word > 2 and word:sub(1, 1) == "-" and word:sub(2, 2) ~= "-"
end

---Whether a node word runs code: an eval flag, one with an attached value (`--eval=x`), or a cluster with an eval
---letter (node's `-pe` is `--print --eval`).
---@param word string
---@return boolean
local function node_eval(word)
  if is_cluster(word) then
    return word:find("[ep]", 2) ~= nil
  end
  return NODE_EVAL_FLAGS[word:match("^([^=]+)=") or word] == true
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
    elseif node_eval(word) then
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

---Whether a python word runs code, reads stdin (a lone `-`), or names a module in the same word: `-c`, or a cluster
---with `c` or `m`, which takes the rest of the word as its code or module (`-uc`, `-cCODE`, `-maider`).
---@param word string
---@return boolean
local function python_eval(word)
  return word == "-c" or word == "-" or (is_cluster(word) and word:find("[cm]", 2) ~= nil)
end

---How many words a python flag word takes. `python3 --help` (3.9.6) is silent on clusters, so this follows the getopt
---that python 3.9.6 was observed to use (`-Wc` is `-W` with the value `c`; `-uW ignore` and `-uX dev` run with the
---next word as the value): a cluster is scanned left to right, and at the first `W` or `X` the rest of the word is its
---value, or the next word when it is the last letter. A cluster with `c` or `m` never gets here (python_eval).
---@param word string a word that starts with `-`
---@return integer words
local function python_flag_words(word)
  if PYTHON_VALUE_FLAGS[word] then
    return 2
  end
  if is_cluster(word) then
    local at = word:find("[WX]", 2)
    if at == #word then
      return 2
    end
  end
  return 1
end

---The script, or the module of `-m`, after the flags of a python command line.
---@param words string[]
---@return string? name
local function python_script(words)
  local i = 1
  while words[i] do
    local word = words[i]
    -- `-m <module>` needs no branch: -m is skipped as a flag and the module is the first word that is not one.
    if word == "--" then
      return words[i + 1] and script_name(words[i + 1])
    elseif python_eval(word) then
      return nil
    elseif word:sub(1, 1) == "-" then
      i = i + python_flag_words(word)
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

---What a process is tested as: its name, or for an interpreter the name of the script it runs, read from one `ps` call.
---The command line is a local value here: it is parsed and dropped, and a failing ps reports the pid, the exit code
---and the first stderr line, never stdout.
---`ps -p <pid>` for a pid that no longer exists exits 1 and prints nothing on either stream (seen on macOS; the macOS
---man page states no exit status for it). That is a process that ended after nvim read its name, which is ordinary for
---short-lived helpers: it is skipped. Any other failure, and exit 0 with nothing printed, is an error.
---@param pid integer
---@param name string the process name nvim or the multiplexer reads
---@param backend string the backend named in an error
---@return string? program the script's name ("" when the interpreter runs none); nil when the process is gone
---@return sidekick_ultra.Error? err
function M.of(pid, name, backend)
  if not M.is_interpreter(name) then
    return name
  end
  local res, err = exec.run({ "ps", "-ww", "-o", "args=", "-p", tostring(pid) }, { backend = backend, cmd = "ps" })
  if not res then
    return nil, err
  end
  if res.code == 1 and res.stdout == "" and res.stderr == "" then
    return nil
  end
  local program = res.code == 0 and M.program(res.stdout) or nil
  if program then
    return program
  end
  local first = vim.split(res.stderr, "\n", { plain = true })[1]
  local msg = res.code == 0 and ("ps printed nothing for pid %d"):format(pid)
    or ("ps exited with %d for pid %d"):format(res.code, pid)
  return nil,
    errors.new("backend_error", first ~= "" and (msg .. ": " .. first) or msg, {
      backend = backend,
      cmd = "ps",
      code = res.code,
    })
end

return M
