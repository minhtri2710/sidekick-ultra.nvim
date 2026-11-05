-- The fixtures in tests/fixtures/tmux follow the shapes a tmux 3.8 probe printed in D8. What is still unverified is
-- listed in UNVERIFIED.txt there. Every tmux call goes through the exec seam; no spec runs tmux.
local backend = require("sidekick-ultra.backend")
local exec = require("sidekick-ultra.exec")
local fake = require("tests.helpers.fake")
local registry = require("sidekick-ultra.registry")
local tmux = require("sidekick-ultra.backends.tmux")
local tools = require("sidekick-ultra.tools")

local errors = require("sidekick-ultra.errors")
local notify = require("tests.helpers.notify")

local expect = MiniTest.expect
local SECRET = "SECRET-TOKEN-xyz"

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/tmux/"
-- The working directory is the last field, and falls back to the start path when tmux has no current path.
local LIST_FORMAT = "#{pane_id}\t#{pane_pid}\t#{session_name}\t#{window_id}\t#{pane_dead}\t"
  .. "#{?pane_current_path,#{pane_current_path},#{pane_start_path}}"
local WORK = "/private/tmp/sku-live-tmux/work"

---@param name string
---@return string
local function fixture(name)
  -- Binary mode: a final NL becomes a last empty item, so joining with NL gives the file back byte for byte.
  return table.concat(vim.fn.readfile(FIXTURES .. name .. ".txt", "b"), "\n")
end

---@param stdout string
---@return table
local function ok(stdout)
  return { code = 0, stdout = stdout, stderr = "" }
end

---@param stderr string
---@return table
local function bad(stderr)
  return { code = 1, stdout = "", stderr = stderr }
end

---Replace `exec.run`. `routes` maps the subcommand (the first argument after an optional `-S <socket>`, or `ps` for a
---`ps` call) to a result table, a fixture-text string, or a function(call number) returning either. A subcommand
---without a route is recorded in `unexpected` and fails with exit 97. `calls[i]` is `{ argv, opts }`.
---@param routes table<string, table|string|fun(n: integer): table|string>
local function record(routes)
  local rec = { calls = {}, unexpected = {}, orig = exec.run }
  local counts = {}
  exec.run = function(argv, opts)
    table.insert(rec.calls, { argv = argv, opts = opts })
    local sub = argv[1] == "ps" and "ps" or argv[2] == "-S" and argv[4] or argv[2]
    counts[sub] = (counts[sub] or 0) + 1
    local route = routes[sub]
    if type(route) == "function" then
      route = route(counts[sub])
    end
    if route == nil then
      table.insert(rec.unexpected, sub)
      return { code = 97, stdout = "", stderr = "unexpected command" }
    end
    return type(route) == "string" and ok(route) or route
  end
  ---The argv of every call, in order.
  function rec.argvs()
    return vim.tbl_map(function(call)
      return call.argv
    end, rec.calls)
  end
  function rec.restore()
    exec.run = rec.orig
  end
  return rec
end

---A process table for `nvim_get_proc` / `nvim_get_proc_children`: pid -> { name, kids }. A pid without an entry is
---unreadable (both calls fail for it).
---@param procs table<integer, { name: string, kids?: integer[] }>
---@return fun() restore
---@return table<integer, integer> visits how many times each pid's children were read
local function fake_procs(procs)
  local get, children = vim.api.nvim_get_proc, vim.api.nvim_get_proc_children
  local visits = {}
  vim.api.nvim_get_proc = function(pid)
    local p = procs[pid]
    if not p then
      error("no such process")
    end
    return { name = p.name, ppid = 1 }
  end
  vim.api.nvim_get_proc_children = function(pid)
    local p = procs[pid]
    if not p then
      error("no such process")
    end
    visits[pid] = (visits[pid] or 0) + 1
    -- A walk that revisits a pid would never end on a cycle; cut it off so a broken walk fails instead of hanging.
    return visits[pid] > 3 and {} or p.kids or {}
  end
  return function()
    vim.api.nvim_get_proc, vim.api.nvim_get_proc_children = get, children
  end, visits
end

describe("tmux backend", function()
  local rec, restore_procs, dir
  local env = {}
  local VARS = { "TMUX", "TMUX_PANE", "TERM_PROGRAM", "PATH" }

  ---@param tmux_opts? table the `tmux` options besides `enabled`
  local function setup(tmux_opts)
    fake.reset(
      { claude = { cmd = fake.INSTALLED }, codex = { cmd = fake.INSTALLED } },
      { tmux = vim.tbl_extend("force", { enabled = false }, tmux_opts or {}) }
    )
  end

  ---Install a fake process table (replacing any earlier one); returns the visit counts.
  ---@param table_ table
  local function use_procs(table_)
    if restore_procs then
      restore_procs()
    end
    local restore, visits = fake_procs(table_)
    restore_procs = restore
    return visits
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for _, var in ipairs(VARS) do
      env[var] = vim.env[var]
    end
    setup()
    -- Every pid is unreadable unless a case installs a table: no case depends on the host's process table.
    use_procs({})
  end)

  after_each(function()
    if rec then
      rec.restore()
      expect.equality(rec.unexpected, {})
      rec = nil
    end
    if restore_procs then
      restore_procs()
      restore_procs = nil
    end
    for _, var in ipairs(VARS) do
      vim.env[var] = env[var]
    end
    vim.fn.delete(dir, "rf")
  end)

  it("satisfies the backend contract and defines no is_running of its own", function()
    expect.equality(backend.check(tmux), true)
    expect.equality(tmux.name, "tmux")
    expect.equality(tmux.is_running, nil)
    -- paste-buffer -S, which send needs, arrived in tmux 3.7; health warns below this.
    expect.equality(tmux.MIN_VERSION, { 3, 7 })
  end)

  describe("available", function()
    it("is the tmux found on PATH, with PATH as its source", function()
      local bin = dir .. "/tmux"
      -- Never run (available() only looks the name up), but if it ever is, it leaves the marker minit fails on.
      vim.fn.writefile({ "#!/bin/sh", 'echo "stub reached" >&2', ': > "$HOME/.sku-stub-reached"', "exit 97" }, bin)
      vim.uv.fs_chmod(bin, 493)
      vim.env.PATH = dir
      expect.equality({ tmux.available() }, { true, vim.fn.exepath(bin), "PATH" })
      vim.env.PATH = "/nonexistent-sku-path"
      expect.equality({ tmux.available() }, { false })
    end)
  end)

  describe("inside", function()
    local function inside(tmux_var, pane)
      vim.env.TMUX, vim.env.TMUX_PANE = tmux_var, pane
      return tmux.inside()
    end

    it("needs both TMUX and TMUX_PANE to be non-empty", function()
      expect.equality(inside("/tmp/t.sock,100,0", "%3"), true)
      expect.equality(inside(nil, "%3"), false)
      expect.equality(inside("", "%3"), false)
      expect.equality(inside("/tmp/t.sock,100,0", nil), false)
      expect.equality(inside("/tmp/t.sock,100,0", ""), false)
    end)

    it("with tmux.socket set, needs nvim's own server to be that socket", function()
      local real = dir .. "/real"
      vim.fn.mkdir(real, "p")
      vim.fn.writefile({}, real .. "/t.sock")
      vim.uv.fs_symlink(real, dir .. "/link")
      local function with_socket(socket, tmux_var)
        setup({ socket = socket })
        return inside(tmux_var, "%3")
      end
      expect.equality(with_socket(real .. "/t.sock", real .. "/t.sock,100,0"), true)
      -- Equal after normalizing, and equal as real paths through a symlinked directory.
      expect.equality(with_socket(dir .. "//real/./t.sock", real .. "/t.sock,100,0"), true)
      expect.equality(with_socket(dir .. "/link/t.sock", real .. "/t.sock,100,0"), true)
      -- A socket that does not exist (no realpath) still compares equal after normalizing.
      expect.equality(with_socket(dir .. "//gone/./t.sock", dir .. "/gone/t.sock,100,0"), true)
      -- Another server, or one that does not exist: not inside.
      expect.equality(with_socket(dir .. "/other.sock", real .. "/t.sock,100,0"), false)
      expect.equality(with_socket(real .. "/t.sock", dir .. "/other.sock,100,0"), false)
      -- The pane and TMUX are still required.
      expect.equality(with_socket(real .. "/t.sock", nil), false)
      setup({ socket = real .. "/t.sock" })
      expect.equality(inside(real .. "/t.sock,100,0", nil), false)
    end)

    it("without tmux.socket, ignores which server TMUX names", function()
      expect.equality(inside("/anywhere/else.sock,100,0", "%3"), true)
    end)

    it("does not look at TERM_PROGRAM", function()
      vim.env.TERM_PROGRAM = "iTerm.app"
      expect.equality(inside("/tmp/t.sock,100,0", "%3"), true)
    end)
  end)

  describe("command line", function()
    it("calls tmux with no -S and no -L by default", function()
      rec = record({ ["list-panes"] = fixture("list_panes_empty") })
      tmux.list(tools.all())
      expect.equality(rec.argvs(), { { "tmux", "list-panes", "-a", "-F", LIST_FORMAT } })
    end)

    it("passes -S <socket> before the subcommand on every call when tmux.socket is set", function()
      setup({ socket = "/tmp/sku.sock" })
      rec = record({
        ["list-panes"] = fixture("list_panes_empty"),
        ["display-message"] = "0\n",
        ["send-keys"] = "",
        ["load-buffer"] = "",
        ["paste-buffer"] = "",
        ["select-window"] = "",
      })
      local s = { pane = "%1" }
      tmux.list(tools.all())
      tmux.send(s, "x")
      tmux.submit(s)
      tmux.focus(s)
      for _, argv in ipairs(rec.argvs()) do
        expect.equality(vim.list_slice(argv, 1, 3), { "tmux", "-S", "/tmp/sku.sock" })
      end
      -- list; send: mode check, load, paste; submit: mode check, send-keys; focus.
      expect.equality(#rec.calls, 7)
    end)

    it("maps a non-zero exit to backend_error carrying the first stderr line", function()
      rec = record({
        ["display-message"] = "0\n",
        ["send-keys"] = bad(fixture("stderr_missing_pane") .. "second line\n"),
      })
      local res, err = tmux.submit({ pane = "%99" })
      expect.equality(res, nil)
      expect.equality(err.id, "backend_error")
      expect.equality(err.backend, "tmux")
      expect.equality(err.cmd, "send-keys")
      expect.equality(err.code, 1)
      expect.equality(err.msg, "tmux exited with 1: can't find pane: %99")
    end)

    it("maps a spawn failure to backend_error", function()
      local orig = exec.run
      exec.run = function(_, opts)
        return nil, require("sidekick-ultra.errors").new("backend_error", "cannot run tmux: boom", opts)
      end
      local list, err = tmux.list(tools.all())
      exec.run = orig
      expect.equality({ list, err.id, err.cmd }, { nil, "backend_error", "list-panes" })
    end)
  end)

  describe("list", function()
    local TREE = {
      [58000] = { name = "zsh", kids = { 58001 } },
      [58001] = { name = "nvim" },
      [58100] = { name = "zsh", kids = { 58101 } },
      [58101] = { name = "claude" },
      [58200] = { name = "codex" },
      [58300] = { name = "zsh", kids = { 58301 } },
      [58301] = { name = "claude" },
      [58400] = { name = "zsh" },
    }

    it("keeps live panes whose process tree runs a tool, with one list-panes call and no other command", function()
      rec = record({ ["list-panes"] = fixture("list_panes") })
      use_procs(TREE)
      local list, err = tmux.list(tools.all())
      expect.equality(err, nil)
      expect.equality(list, {
        {
          id = "tmux:%1",
          backend = "tmux",
          tool = "claude",
          cwd = WORK,
          pid = 58101,
          proc_name = "claude",
          pane = "%1",
          tmux_session = "main",
          window_id = "@0",
        },
        {
          id = "tmux:%2",
          backend = "tmux",
          tool = "codex",
          cwd = WORK,
          pid = 58200,
          proc_name = "codex",
          pane = "%2",
          tmux_session = "other",
          window_id = "@1",
        },
      })
      expect.equality(#rec.calls, 1)
    end)

    it("lists no pane for a tool that is not configured", function()
      rec = record({ ["list-panes"] = fixture("list_panes") })
      use_procs(TREE)
      local list = tmux.list({ codex = tools.get("codex") })
      expect.equality(
        vim.tbl_map(function(s)
          return s.id
        end, list),
        { "tmux:%2" }
      )
    end)

    it("walks the tree breadth-first: the shallowest tool wins over deeper ones on either side", function()
      rec = record({ ["list-panes"] = fixture("list_panes") })
      use_procs({
        [58100] = { name = "zsh", kids = { 1, 2, 3 } },
        [1] = { name = "bash", kids = { 11 } },
        [11] = { name = "sh", kids = { 111 } },
        [111] = { name = "claude" },
        [2] = { name = "sh", kids = { 22 } },
        [22] = { name = "codex" },
        [3] = { name = "bash", kids = { 33 } },
        [33] = { name = "sh", kids = { 333 } },
        [333] = { name = "claude" },
      })
      local list = tmux.list(tools.all())
      expect.equality(#list, 1)
      expect.equality({ list[1].tool, list[1].pid, list[1].proc_name }, { "codex", 22, "codex" })
    end)

    it("reads each process once, so a cycle ends, and skips an unreadable process", function()
      rec = record({ ["list-panes"] = fixture("list_panes") })
      local procs = {
        [58100] = { name = "zsh", kids = { 58100, 7, 8 } },
        [8] = { name = "claude", kids = { 58100 } },
      }
      local visits
      visits = use_procs(procs)
      local list = tmux.list(tools.all())
      expect.equality({ #list, list[1].pid }, { 1, 8 })
      expect.equality(visits[58100], 1)
      rec.restore()
      -- No tool anywhere: the walk still ends, having read each process once.
      rec = record({ ["list-panes"] = fixture("list_panes") })
      procs[8].name = "sh"
      visits = use_procs(procs)
      expect.equality({ tmux.list(tools.all()) }, { {} })
      expect.equality({ visits[58100], visits[8] }, { 1, 1 })
    end)

    it("tests each process with the tool's is_proc as { pid, cmd = the name nvim reads }", function()
      local seen = {}
      local claude = vim.tbl_extend("force", tools.get("claude"), {
        is_proc = function(proc)
          table.insert(seen, proc)
          return proc.cmd == "claude"
        end,
      })
      rec = record({ ["list-panes"] = fixture("list_panes") })
      use_procs(TREE)
      local list = tmux.list({ claude = claude })
      expect.equality(
        vim.tbl_filter(function(proc)
          return proc.pid >= 58100 and proc.pid <= 58101
        end, seen),
        { { pid = 58100, cmd = "zsh" }, { pid = 58101, cmd = "claude" } }
      )
      expect.equality({ #list, list[1].pid, list[1].proc_name }, { 1, 58101, "claude" })
    end)

    it("keeps a working directory that holds a tab whole, because it is the last field", function()
      rec = record({ ["list-panes"] = fixture("list_panes_tab_in_path") })
      use_procs({ [58100] = { name = "claude" } })
      local list, err = tmux.list(tools.all())
      expect.equality(err, nil)
      expect.equality(list[1].cwd, "/private/tmp/sku-live-tmux/a\tb")
    end)

    it("lists nothing for an empty server", function()
      rec = record({ ["list-panes"] = fixture("list_panes_empty") })
      expect.equality({ tmux.list(tools.all()) }, { {} })
    end)

    it("lists nothing, without an error, when no server answers", function()
      rec = record({ ["list-panes"] = bad(fixture("stderr_no_server")) })
      expect.equality({ tmux.list(tools.all()) }, { {} })
      rec.restore()
      rec = record({ ["list-panes"] = bad(fixture("stderr_no_socket")) })
      expect.equality({ tmux.list(tools.all()) }, { {} })
    end)

    it("reports any other failure of list-panes as backend_error", function()
      rec = record({ ["list-panes"] = bad("error connecting to /x/t.sock (Permission denied)\n") })
      local list, err = tmux.list(tools.all())
      expect.equality(list, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "list-panes", 1 })
      expect.equality(err.msg:find("Permission denied", 1, true) ~= nil, true)
    end)

    it("fails closed on a row with the wrong shape", function()
      for _, name in ipairs({ "list_panes_bad_fields", "list_panes_bad_id", "list_panes_bad_pid" }) do
        rec = record({ ["list-panes"] = fixture(name) })
        local list, err = tmux.list(tools.all())
        expect.equality({ list, err.id }, { nil, "backend_error" })
        rec.restore()
      end
      rec = nil
    end)

    it("fails when a matched pane has no working directory", function()
      rec = record({ ["list-panes"] = fixture("list_panes_no_cwd") })
      use_procs({ [58100] = { name = "claude" } })
      local list, err = tmux.list(tools.all())
      expect.equality({ list, err.id }, { nil, "backend_error" })
      expect.equality(err.msg:find("%1", 1, true) ~= nil, true)
    end)
  end)

  -- A tool installed as a node or python script runs as its interpreter: for those processes, and only those, one
  -- `ps -ww -o args= -p <pid>` call reads the command line, and the script's name is what a tool is matched against.
  describe("interpreters", function()
    local PANES = "list_panes"
    local PS = { "ps", "-ww", "-o", "args=", "-p", "58100" }

    before_each(function()
      fake.reset(
        { claude = { cmd = fake.INSTALLED }, gemini = { cmd = fake.INSTALLED }, aider = { cmd = fake.INSTALLED } },
        { tmux = { enabled = false } }
      )
    end)

    ---ps answers per pid, from the pid in the call (`-p <pid>`); a pid without an answer fails like a missing process.
    ---@param lines table<integer, string|table>
    ---@return fun(n: integer): table|string
    local function ps_route(lines)
      return function()
        local pid = tonumber(rec.calls[#rec.calls].argv[6])
        return lines[pid] or { code = 1, stdout = "", stderr = "" }
      end
    end

    ---The pane %1 (pid 58100) runs `proc`, whose command line is `line`. Returns the tool found, if any.
    ---@param proc string
    ---@param line string
    ---@return table[] sessions
    local function discover(proc, line)
      rec = record({ ["list-panes"] = fixture(PANES), ps = ps_route({ [58100] = line .. "\n" }) })
      use_procs({ [58100] = { name = proc } })
      local list, err = tmux.list(tools.all())
      expect.equality(err, nil)
      rec.restore()
      local ps_calls = vim.tbl_filter(function(argv)
        return argv[1] == "ps"
      end, rec.argvs())
      expect.equality(ps_calls, { PS })
      rec = nil
      return list
    end

    it("finds a node tool by its script name, with one ps call, and records the interpreter's process", function()
      local list = discover("node", "/opt/homebrew/bin/node /x/bin/gemini --flag value")
      expect.equality(list, {
        {
          id = "tmux:%1",
          backend = "tmux",
          tool = "gemini",
          cwd = WORK,
          pid = 58100,
          proc_name = "node",
          pane = "%1",
          tmux_session = "main",
          window_id = "@0",
        },
      })
    end)

    it("runs ps through the exec seam with the pid and no tmux socket flag, even when tmux.socket is set", function()
      fake.reset({ gemini = { cmd = fake.INSTALLED } }, { tmux = { enabled = false, socket = "/tmp/sku.sock" } })
      rec = record({ ["list-panes"] = fixture(PANES), ps = "node /x/bin/gemini\n" })
      use_procs({ [58100] = { name = "node" } })
      tmux.list(tools.all())
      expect.equality(rec.argvs()[2], PS)
      expect.equality({ rec.calls[2].opts.backend, rec.calls[2].opts.cmd }, { "tmux", "ps" })
    end)

    it("keeps a session whose liveness is the interpreter's process name, as registry.is_running reads it", function()
      local list = discover("node", "node /x/bin/gemini")
      expect.equality(registry.is_running(list[1]), true)
      use_procs({ [58100] = { name = "zsh" } })
      expect.equality(registry.is_running(list[1]), false)
    end)

    it("takes every interpreter name and the script word after its flags", function()
      local cases = {
        { "node", "node /x/bin/gemini", "gemini" },
        { "nodejs", "nodejs /x/bin/gemini", "gemini" },
        { "bun", "bun /x/bin/gemini", "gemini" },
        { "node", "node -- /x/bin/gemini", "gemini" },
        { "node", "node --require ./hook.js --inspect=9229 /x/bin/gemini", "gemini" },
        { "python", "python /x/bin/aider", "aider" },
        { "python3", "python3 -m aider --model x", "aider" },
        { "python3.12", "python3.12 -u /x/bin/aider.py", "aider" },
        { "Python", "/usr/bin/Python -W ignore -m aider", "aider" },
      }
      for _, case in ipairs(cases) do
        local list = discover(case[1], case[2])
        expect.equality({ case[2], #list, list[1] and list[1].tool }, { case[2], 1, case[3] })
        expect.equality(list[1].proc_name, case[1])
      end
    end)

    it("finds no tool for an interpreter that runs no script, or a script that is not a tool", function()
      for _, case in ipairs({
        { "node", "node -e gemini" },
        { "node", "node --eval gemini" },
        { "node", "node -p gemini" },
        { "node", "node --print gemini" },
        { "node", "node" },
        { "python3", "python3 -c aider" },
        { "python3", "python3" },
        { "node", "node /x/dist/index.js" },
        { "python3", "python3 -m pip install gemini" },
        -- the tool's name only after the script
        { "node", "node /x/bin/other gemini" },
        { "node", "node /x/bin/other --name=gemini" },
      }) do
        expect.equality({ case[2], discover(case[1], case[2]) }, { case[2], {} })
      end
    end)

    it("does not match the interpreter's own name, so a tool needs its script name", function()
      fake.reset({ nodetool = { cmd = fake.INSTALLED, is_proc = "^node$" } }, { tmux = { enabled = false } })
      rec = record({ ["list-panes"] = fixture(PANES), ps = "node /x/bin/other\n" })
      use_procs({ [58100] = { name = "node" } })
      expect.equality({ tmux.list(tools.all()) }, { {} })
    end)

    it("reads no command line for a process that is not an interpreter", function()
      rec = record({ ["list-panes"] = fixture(PANES) })
      use_procs({
        [58100] = { name = "zsh", kids = { 1, 2, 3 } },
        [1] = { name = "nodemon" },
        [2] = { name = "Python3" },
        [3] = { name = "claude" },
      })
      local list = tmux.list(tools.all())
      expect.equality({ #list, list[1].tool, list[1].pid }, { 1, "claude", 3 })
      expect.equality(#rec.calls, 1)
    end)

    it(
      "keeps walking below an interpreter that is not a tool, one ps call per interpreter, none after a match",
      function()
        rec = record({
          ["list-panes"] = fixture(PANES),
          ps = ps_route({
            [58100] = "node /x/bin/other\n",
            [1] = "python3 -m other\n",
            [2] = "node /x/bin/gemini\n",
            [3] = "node /x/bin/aider\n",
          }),
        })
        use_procs({
          [58100] = { name = "node", kids = { 1, 2 } },
          [1] = { name = "python3", kids = { 11 } },
          [11] = { name = "claude" },
          [2] = { name = "node", kids = { 3 } },
          [3] = { name = "node" },
        })
        local list = tmux.list(tools.all())
        -- 2 is the shallowest match (gemini); the claude below 1 and the aider below 2 are deeper.
        expect.equality({ #list, list[1].tool, list[1].pid, list[1].proc_name }, { 1, "gemini", 2, "node" })
        local pids = {}
        for _, argv in ipairs(rec.argvs()) do
          if argv[1] == "ps" then
            table.insert(pids, argv[6])
          end
        end
        expect.equality(pids, { "58100", "1", "2" })
      end
    )

    it("keeps walking below an interpreter that runs code and no script", function()
      rec = record({ ["list-panes"] = fixture(PANES), ps = ps_route({ [58100] = "node -e " .. SECRET .. "\n" }) })
      use_procs({ [58100] = { name = "node", kids = { 1 } }, [1] = { name = "claude" } })
      local list = tmux.list(tools.all())
      expect.equality({ #list, list[1].tool, list[1].pid }, { 1, "claude", 1 })
    end)

    describe("a process that ended before ps ran", function()
      -- ps -p for a pid that is gone: exit 1 and nothing on either stream. The process is skipped, not an error.
      local GONE = { code = 1, stdout = "", stderr = "" }

      it("is skipped, and a tool later in the tree is still found", function()
        rec = record({
          ["list-panes"] = fixture(PANES),
          ps = ps_route({
            [1] = GONE,
            [2] = "node /x/bin/other --token " .. SECRET .. "\n",
            [3] = "node /x/bin/gemini --api-key " .. SECRET .. "\n",
          }),
        })
        use_procs({
          [58100] = { name = "zsh", kids = { 1, 2, 3 } },
          [1] = { name = "node", kids = { 11 } },
          [11] = { name = "claude" },
          [2] = { name = "node" },
          [3] = { name = "node" },
        })
        local list, err = tmux.list(tools.all())
        expect.equality(err, nil)
        -- 3 is the shallowest tool: 1 is gone (its child, read from nvim, is deeper), 2 runs another script.
        expect.equality({ #list, list[1].tool, list[1].pid, list[1].proc_name }, { 1, "gemini", 3, "node" })
        expect.equality(vim.inspect({ list, rec.calls }):find(SECRET, 1, true), nil)
      end)

      it("keeps walking below the gone process when nvim can still read its children", function()
        rec = record({ ["list-panes"] = fixture(PANES), ps = ps_route({ [58100] = GONE }) })
        use_procs({ [58100] = { name = "node", kids = { 1 } }, [1] = { name = "claude" } })
        local list, err = tmux.list(tools.all())
        expect.equality(err, nil)
        expect.equality({ #list, list[1].tool, list[1].pid }, { 1, "claude", 1 })
      end)

      it("gives no session when nothing else in the pane is a tool", function()
        rec = record({ ["list-panes"] = fixture(PANES), ps = ps_route({ [58100] = GONE }) })
        use_procs({ [58100] = { name = "node" } })
        expect.equality({ tmux.list(tools.all()) }, { {} })
      end)

      it("does not stop start, which records the pane's root process", function()
        vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
        rec = record({ ["split-window"] = fixture("split_window"), ps = ps_route({ [58500] = GONE }) })
        use_procs({ [58500] = { name = "node" } })
        local session, err = tmux.start(tools.get("gemini"), { cwd = "/w", env = {} })
        expect.equality(err, nil)
        expect.equality({ session.pid, session.proc_name }, { 58500, "node" })
      end)
    end)

    it("start records the tool's script process in the new pane when it is already up", function()
      vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
      rec = record({ ["split-window"] = fixture("split_window"), ps = ps_route({ [58500] = "node /x/bin/gemini\n" }) })
      use_procs({ [58500] = { name = "node" } })
      local session, err = tmux.start(tools.get("gemini"), { cwd = "/w", env = {} })
      expect.equality(err, nil)
      expect.equality(
        { session.id, session.tool, session.pid, session.proc_name },
        { "tmux:%5", "gemini", 58500, "node" }
      )
    end)

    it("start falls back to the pane's root process when its script is not the tool", function()
      vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
      rec = record({ ["split-window"] = fixture("split_window"), ps = ps_route({ [58500] = "node /x/bin/other\n" }) })
      use_procs({ [58500] = { name = "node" } })
      local session = tmux.start(tools.get("gemini"), { cwd = "/w", env = {} })
      expect.equality({ session.pid, session.proc_name }, { 58500, "node" })
    end)

    describe("a failing ps", function()
      ---@param route table|string|fun(n: integer): table|string
      ---@return sidekick_ultra.Error
      local function failing(route)
        rec = record({ ["list-panes"] = fixture(PANES), ps = route })
        use_procs({ [58100] = { name = "node" } })
        local list, err = tmux.list(tools.all())
        rec.restore()
        expect.equality(list, nil)
        return err
      end

      it("is a backend_error naming the pid, the exit code and the first stderr line", function()
        local err = failing({
          code = 3,
          stdout = "node /x/bin/gemini --api-key " .. SECRET .. "\n",
          stderr = "ps: boom\nsecond\n",
        })
        expect.equality({ err.id, err.backend, err.cmd, err.code }, { "backend_error", "tmux", "ps", 3 })
        expect.equality(err.msg, "ps exited with 3 for pid 58100: ps: boom")
      end)

      it("names no stderr when there is none", function()
        local err = failing({ code = 2, stdout = "", stderr = "" })
        expect.equality(err.msg, "ps exited with 2 for pid 58100")
      end)

      it("is an error for exit 1 unless both streams are empty: stderr text, or stdout, makes it a failure", function()
        local err = failing({ code = 1, stdout = "", stderr = "ps: illegal option\n" })
        expect.equality(
          { err.id, err.code, err.msg },
          { "backend_error", 1, "ps exited with 1 for pid 58100: ps: illegal option" }
        )
        err = failing({ code = 1, stdout = "node /x/bin/gemini " .. SECRET .. "\n", stderr = "" })
        expect.equality({ err.id, err.code, err.msg }, { "backend_error", 1, "ps exited with 1 for pid 58100" })
        expect.equality(vim.inspect(err):find(SECRET, 1, true), nil)
      end)

      it("is an error for exit 0 with nothing printed", function()
        for _, stdout in ipairs({ "", "\n", "  \n" }) do
          local err = failing({ code = 0, stdout = stdout, stderr = "" })
          expect.equality(
            { err.id, err.cmd, err.code, err.msg },
            { "backend_error", "ps", 0, "ps printed nothing for pid 58100" }
          )
        end
      end)

      it("keeps stdout out of the error and out of its toast", function()
        local cap = notify.capture()
        local err = failing({ code = 1, stdout = "node /x/bin/gemini --api-key " .. SECRET .. "\n", stderr = "gone\n" })
        errors.notify(err)
        cap.restore()
        expect.equality(#cap.calls, 1)
        expect.equality(vim.inspect({ err, cap.calls }):find(SECRET, 1, true), nil)
      end)

      it("is the exec error itself when ps cannot be spawned", function()
        local orig = exec.run
        exec.run = function(argv, opts)
          if argv[1] == "ps" then
            return nil, errors.new("backend_error", "cannot run ps: boom", opts)
          end
          return ok(fixture(PANES))
        end
        use_procs({ [58100] = { name = "node" } })
        local list, err = tmux.list(tools.all())
        exec.run = orig
        expect.equality({ list, err.id, err.cmd, err.msg }, { nil, "backend_error", "ps", "cannot run ps: boom" })
      end)

      it("stops start at once and names the pane left open", function()
        vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
        rec = record({
          ["split-window"] = fixture("split_window"),
          ps = { code = 2, stdout = "node " .. SECRET .. "\n", stderr = "boom\n" },
        })
        use_procs({ [58500] = { name = "node" } })
        local session, err = tmux.start(tools.get("gemini"), { cwd = "/w", env = {} })
        expect.equality(session, nil)
        expect.equality({ err.id, err.cmd }, { "backend_error", "split-window" })
        expect.equality(err.msg, "ps exited with 2 for pid 58500: boom; pane %5 was left open")
        expect.equality(vim.inspect(err):find(SECRET, 1, true), nil)
      end)
    end)

    -- Supervisor condition: the command line beyond the script word may carry a secret. Every command line below
    -- holds SECRET; nothing the backend returns, raises or notifies may hold it.
    describe("command line arguments", function()
      local LINES = {
        { "node", "node /x/bin/gemini --api-key " .. SECRET, "gemini" },
        { "node", "node --require " .. SECRET .. " /x/bin/gemini", "gemini" },
        { "node", 'node -e "' .. SECRET .. '"', nil },
        { "python3", "python3 -m aider --token " .. SECRET, "aider" },
        { "python3", 'python3 -c "' .. SECRET .. '"', nil },
        { "node", 'node -pe "' .. SECRET .. '"', nil },
        { "node", 'node -ep "' .. SECRET .. '"', nil },
        { "node", "node --eval=" .. SECRET, nil },
        { "node", "node --print=" .. SECRET, nil },
        { "node", "node --run " .. SECRET, nil },
        { "node", "node --env-file " .. SECRET .. " /x/bin/gemini", "gemini" },
        { "node", "node --title " .. SECRET .. " /x/bin/gemini", "gemini" },
        { "python3", 'python3 -uc "' .. SECRET .. '"', nil },
        { "python3", "python3 -c" .. SECRET, nil },
        { "python3", "python3 -Wc /x/bin/aider --token " .. SECRET, nil },
        { "python3", "python3 -maider --token " .. SECRET, nil },
        { "python3", "python3 --check-hash-based-pycs " .. SECRET .. " /x/bin/aider", "aider" },
        { "node", "node - " .. SECRET, nil },
        { "python3", "python3 - " .. SECRET, nil },
      }

      it("reach no session and no recorded call of list", function()
        for _, case in ipairs(LINES) do
          rec = record({ ["list-panes"] = fixture(PANES), ps = case[2] .. "\n" })
          use_procs({ [58100] = { name = case[1] } })
          local list, err = tmux.list(tools.all())
          expect.equality(err, nil)
          expect.equality(list[1] and list[1].tool, case[3])
          expect.equality(vim.inspect({ list, rec.calls }):find(SECRET, 1, true), nil)
          rec.restore()
          rec = nil
        end
      end)

      it("reach no session of start", function()
        vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
        for _, case in ipairs(LINES) do
          rec = record({ ["split-window"] = fixture("split_window"), ps = case[2] .. "\n" })
          use_procs({ [58500] = { name = case[1] } })
          local session, err = tmux.start(tools.get("gemini"), { cwd = "/w", env = {} })
          expect.equality(err, nil)
          expect.equality(vim.inspect({ session, rec.calls }):find(SECRET, 1, true), nil)
          rec.restore()
          rec = nil
        end
      end)

      it("reach no session of registry.discover, and no notify", function()
        local cap = notify.capture()
        registry.register(tmux)
        for _, case in ipairs(LINES) do
          rec = record({ ["list-panes"] = fixture(PANES), ps = case[2] .. "\n" })
          use_procs({ [58100] = { name = case[1] } })
          local list = registry.discover()
          expect.equality(vim.inspect({ list, cap.calls }):find(SECRET, 1, true), nil)
          rec.restore()
          rec = nil
        end
        cap.restore()
        expect.equality(cap.calls, {})
      end)

      it("are not kept by the exec seam, which holds no state", function()
        local res = exec.run({ "/bin/sh", "-c", "echo " .. SECRET })
        expect.equality(res.stdout, SECRET .. "\n")
        for name, mod in pairs(package.loaded) do
          if type(name) == "string" and name:find("^sidekick%-ultra") then
            expect.equality({ name, vim.inspect(mod):find(SECRET, 1, true) }, { name, nil })
          end
        end
        expect.equality(vim.fn.execute("messages"):find(SECRET, 1, true), nil)
      end)
    end)
  end)

  describe("start", function()
    local OPTS_ENV = {}

    ---The new pane's root process is pid 58500 (tests/fixtures/tmux/split_window.txt), a shell that is not a tool.
    local function split_route()
      return fixture("split_window")
    end

    before_each(function()
      vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
      use_procs({ [58500] = { name = "sh" } })
    end)

    it("splits right of nvim's pane without focus, with cwd, sorted env, and the command as argv", function()
      rec = record({ ["split-window"] = split_route() })
      local tool = vim.tbl_extend("force", tools.get("claude"), { cmd = { "claude", "--flag", "a b" } })
      local session, err = tmux.start(tool, { cwd = "/work/dir", env = { B = "2", A = "1" } })
      expect.equality(err, nil)
      expect.equality(rec.argvs(), {
        {
          "tmux",
          "split-window",
          "-h",
          "-d",
          "-t",
          "%0",
          "-c",
          "/work/dir",
          "-e",
          "A=1",
          "-e",
          "B=2",
          "-P",
          "-F",
          "#{pane_id}\t#{pane_pid}",
          "--",
          "claude",
          "--flag",
          "a b",
        },
      })
      expect.equality(session.id, "tmux:%5")
    end)

    it("passes a one-element command shell-escaped, because tmux runs it through sh -c", function()
      rec = record({ ["split-window"] = split_route() })
      tmux.start(vim.tbl_extend("force", tools.get("claude"), { cmd = { "/opt/my tools/cl'aude" } }), {
        cwd = "/w",
        env = OPTS_ENV,
      })
      local argv = rec.argvs()[1]
      expect.equality(vim.list_slice(argv, #argv - 1), { "--", "'/opt/my tools/cl'\\''aude'" })
      rec.restore()
      rec = record({ ["split-window"] = split_route() })
      tmux.start(vim.tbl_extend("force", tools.get("claude"), { cmd = { "claude" } }), { cwd = "/w", env = OPTS_ENV })
      argv = rec.argvs()[1]
      expect.equality(vim.list_slice(argv, #argv - 1), { "--", "'claude'" })
      expect.equality(vim.tbl_contains(argv, "-e"), false)
    end)

    it("uses -S when tmux.socket is set", function()
      setup({ socket = "/tmp/sku.sock" })
      rec = record({ ["split-window"] = split_route() })
      tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality(vim.list_slice(rec.argvs()[1], 1, 4), { "tmux", "-S", "/tmp/sku.sock", "split-window" })
    end)

    it("returns a session that counts as running at once, and does not focus", function()
      rec = record({ ["split-window"] = split_route() })
      local session = tmux.start(tools.get("claude"), { cwd = "/work/dir", env = OPTS_ENV })
      expect.equality(session, {
        id = "tmux:%5",
        backend = "tmux",
        tool = "claude",
        cwd = "/work/dir",
        pid = 58500,
        proc_name = "sh",
        pane = "%5",
      })
      -- registry.is_running reads the process through nvim: the record matches what nvim reports now, not later.
      expect.equality(registry.is_running(session), true)
      use_procs({ [58500] = { name = "other" } })
      expect.equality(registry.is_running(session), false)
      expect.equality(#rec.calls, 1)
    end)

    it("records the tool's own process when the tree already runs it", function()
      rec = record({ ["split-window"] = split_route() })
      use_procs({ [58500] = { name = "zsh", kids = { 58501 } }, [58501] = { name = "claude" } })
      local session = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session.pid, session.proc_name }, { 58501, "claude" })
    end)

    it("records the pane's root process, not another tool's, when the started tool is not up yet", function()
      rec = record({ ["split-window"] = split_route() })
      -- A codex below the shell is not this claude session: only the started tool counts.
      use_procs({ [58500] = { name = "zsh", kids = { 58501 } }, [58501] = { name = "codex" } })
      local session = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session.pid, session.proc_name }, { 58500, "zsh" })
    end)

    it("returns the tmux error and creates nothing else when split-window fails", function()
      rec = record({ ["split-window"] = bad("no space for new pane\n") })
      local session, err = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session, err.id, err.cmd }, { nil, "backend_error", "split-window" })
      expect.equality(#rec.calls, 1)
    end)

    it("takes the id and pid from the printed line, with or without its final newline", function()
      rec = record({ ["split-window"] = "%5\t58500" })
      local session = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session.id, session.pid }, { "tmux:%5", 58500 })
    end)

    it("fails when tmux prints no pane id, or more than one line", function()
      for _, out in ipairs({ "\n", "%5\n", "%5\t58500 extra\n", "%5\t58500\n%6\t58600\n", "5\t58500\n", "x%5\t58500\n" }) do
        rec = record({ ["split-window"] = out })
        local session, err = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
        expect.equality({ session, err.id }, { nil, "backend_error" })
        rec.restore()
      end
      rec = nil
    end)

    it("fails, naming the pane left open, when its process is not visible to this nvim", function()
      rec = record({ ["split-window"] = split_route() })
      use_procs({})
      local session, err = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session, err.id }, { nil, "backend_error" })
      expect.equality(err.msg:find("%5", 1, true) ~= nil and err.msg:find("left open", 1, true) ~= nil, true)
    end)
  end)

  describe("send", function()
    it(
      "checks the pane's mode, loads the text from stdin into a named buffer, pastes it raw and deletes the buffer",
      function()
        rec = record({ ["display-message"] = "0\n", ["load-buffer"] = "", ["paste-buffer"] = "" })
        local text = "line one\nline two\n  indented"
        expect.equality(tmux.send({ pane = "%2" }, text), true)
        local mode, load, paste = rec.argvs()[1], rec.argvs()[2], rec.argvs()[3]
        local buffer = load[4]
        expect.equality(buffer:match("^sku%-%d+%-%d+$") ~= nil, true)
        expect.equality(mode, { "tmux", "display-message", "-p", "-t", "%2", "#{pane_in_mode}" })
        expect.equality(load, { "tmux", "load-buffer", "-b", buffer, "-" })
        expect.equality(paste, { "tmux", "paste-buffer", "-b", buffer, "-d", "-r", "-S", "-t", "%2" })
        expect.equality(rec.calls[2].opts.stdin, text)
        -- Nothing else: no copy-mode call for a pane in no mode, and no key, so no Enter.
        expect.equality(#rec.calls, 3)
      end
    )

    it("leaves copy mode (or any mode) before it loads and pastes", function()
      for _, count in ipairs({ "1\n", "2\n" }) do
        rec = record({
          ["display-message"] = count,
          ["copy-mode"] = "",
          ["load-buffer"] = "",
          ["paste-buffer"] = "",
        })
        expect.equality(tmux.send({ pane = "%2" }, "x"), true)
        local subs = vim.tbl_map(function(argv)
          return argv[2]
        end, rec.argvs())
        expect.equality(subs, { "display-message", "copy-mode", "load-buffer", "paste-buffer" })
        expect.equality(rec.argvs()[2], { "tmux", "copy-mode", "-q", "-t", "%2" })
        rec.restore()
      end
      rec = nil
    end)

    it("sends nothing when the mode cannot be read or left", function()
      for _, routes in ipairs({
        { ["display-message"] = bad(fixture("stderr_missing_pane")) },
        { ["display-message"] = "yes\n" },
        { ["display-message"] = "1\n", ["copy-mode"] = bad("pane is busy\n") },
      }) do
        rec = record(routes)
        local res, err = tmux.send({ pane = "%2" }, "x")
        expect.equality({ res, err.id }, { nil, "backend_error" })
        expect.equality(
          vim.tbl_contains(
            vim.tbl_map(function(argv)
              return argv[2]
            end, rec.argvs()),
            "load-buffer"
          ),
          false
        )
        rec.restore()
      end
      rec = nil
    end)

    it("reports a pane tmux no longer knows (exit 0, empty output) as not found, and loads nothing", function()
      -- tmux 3.8 answers display-message -p -t <missing pane> with exit 0 and no output, not an error.
      rec = record({ ["display-message"] = fixture("display_pane_gone") })
      local res, err = tmux.send({ pane = "%999" }, "x")
      expect.equality(
        { res, err.id, err.cmd, err.msg },
        { nil, "backend_error", "display-message", "tmux pane %999 not found" }
      )
      expect.equality(#rec.calls, 1)
    end)

    it("names an unreadable mode count in the error", function()
      rec = record({ ["display-message"] = "yes\n" })
      local _, err = tmux.send({ pane = "%2" }, "x")
      expect.equality(err.msg, "tmux printed an unexpected mode count for pane %2: yes")
    end)

    it("uses a different buffer for each send", function()
      rec = record({ ["display-message"] = "0\n", ["load-buffer"] = "", ["paste-buffer"] = "" })
      tmux.send({ pane = "%2" }, "a")
      tmux.send({ pane = "%2" }, "b")
      expect.no_equality(rec.argvs()[2][4], rec.argvs()[5][4])
    end)

    it("sends nothing for an empty text, not even the mode check", function()
      rec = record({})
      expect.equality(tmux.send({ pane = "%2" }, ""), true)
      expect.equality(rec.calls, {})
    end)

    it("stops when the buffer cannot be loaded, without pasting", function()
      rec = record({ ["display-message"] = "0\n", ["load-buffer"] = bad("no server running\n") })
      local res, err = tmux.send({ pane = "%2" }, "x")
      expect.equality({ res, err.id, err.cmd }, { nil, "backend_error", "load-buffer" })
      expect.equality(#rec.calls, 2)
    end)

    it("deletes the buffer and reports the pane error when the paste fails", function()
      rec = record({
        ["display-message"] = "0\n",
        ["load-buffer"] = "",
        ["paste-buffer"] = bad(fixture("stderr_missing_pane")),
        ["delete-buffer"] = "",
      })
      local res, err = tmux.send({ pane = "%99" }, "x")
      expect.equality({ res, err.id, err.cmd }, { nil, "backend_error", "paste-buffer" })
      expect.equality(err.msg, "tmux exited with 1: can't find pane: %99")
      local buffer = rec.argvs()[2][4]
      expect.equality(rec.argvs()[4], { "tmux", "delete-buffer", "-b", buffer })
    end)
  end)

  describe("submit", function()
    it("checks the pane's mode, then sends Enter to the pane", function()
      rec = record({ ["display-message"] = "0\n", ["send-keys"] = "" })
      expect.equality(tmux.submit({ pane = "%2" }), true)
      expect.equality(rec.argvs(), {
        { "tmux", "display-message", "-p", "-t", "%2", "#{pane_in_mode}" },
        { "tmux", "send-keys", "-t", "%2", "Enter" },
      })
    end)

    it("leaves copy mode before Enter, because in a mode Enter would go to the mode", function()
      rec = record({ ["display-message"] = "1\n", ["copy-mode"] = "", ["send-keys"] = "" })
      expect.equality(tmux.submit({ pane = "%2" }), true)
      expect.equality(rec.argvs(), {
        { "tmux", "display-message", "-p", "-t", "%2", "#{pane_in_mode}" },
        { "tmux", "copy-mode", "-q", "-t", "%2" },
        { "tmux", "send-keys", "-t", "%2", "Enter" },
      })
    end)

    it("reports a pane tmux no longer knows (exit 0, empty output) as not found, and presses no Enter", function()
      rec = record({ ["display-message"] = fixture("display_pane_gone") })
      local res, err = tmux.submit({ pane = "%999" })
      expect.equality(
        { res, err.id, err.cmd, err.msg },
        { nil, "backend_error", "display-message", "tmux pane %999 not found" }
      )
      expect.equality(#rec.calls, 1)
    end)

    it("presses no Enter when the mode cannot be read or left", function()
      for _, routes in ipairs({
        { ["display-message"] = bad(fixture("stderr_missing_pane")) },
        { ["display-message"] = "?\n" },
        { ["display-message"] = "1\n", ["copy-mode"] = bad("pane is busy\n") },
      }) do
        rec = record(routes)
        local res, err = tmux.submit({ pane = "%2" })
        expect.equality({ res, err.id }, { nil, "backend_error" })
        expect.equality(
          vim.tbl_contains(
            vim.tbl_map(function(argv)
              return argv[2]
            end, rec.argvs()),
            "send-keys"
          ),
          false
        )
        rec.restore()
      end
      rec = nil
    end)
  end)

  describe("focus", function()
    local SELECT = { "tmux", "select-window", "-t", "%2", ";", "select-pane", "-t", "%2" }

    it("selects the window and the pane in one invocation, with ; as its own argument", function()
      vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
      rec = record({ ["select-window"] = "" })
      expect.equality(tmux.focus({ pane = "%2", tmux_session = "other" }), true)
      expect.equality(rec.argvs(), { SELECT })
    end)

    it("adds switch-client when nvim is inside tmux and the pane is in another session", function()
      vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
      rec = record({ ["display-message"] = fixture("display_session"), ["select-window"] = "" })
      expect.equality(tmux.focus({ pane = "%2", tmux_session = "other" }), true)
      expect.equality(rec.argvs(), {
        { "tmux", "display-message", "-p", "-t", "%0", "#{session_name}" },
        vim.list_extend(vim.deepcopy(SELECT), { ";", "switch-client", "-t", "%2" }),
      })
    end)

    it("leaves switch-client out when the pane is in nvim's own session", function()
      vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
      rec = record({ ["display-message"] = fixture("display_session"), ["select-window"] = "" })
      expect.equality(tmux.focus({ pane = "%2", tmux_session = "main" }), true)
      expect.equality(rec.argvs()[2], SELECT)
    end)

    it("skips the session lookup for a pane tmux started in nvim's own session", function()
      vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
      rec = record({ ["select-window"] = "" })
      expect.equality(tmux.focus({ pane = "%2" }), true)
      expect.equality(rec.argvs(), { SELECT })
    end)

    it("returns the error of the session lookup and selects nothing", function()
      vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
      rec = record({ ["display-message"] = bad("can't find pane: %0\n") })
      local res, err = tmux.focus({ pane = "%2", tmux_session = "other" })
      expect.equality({ res, err.id, err.cmd }, { nil, "backend_error", "display-message" })
      expect.equality(#rec.calls, 1)
    end)

    it("returns the error of a missing pane", function()
      vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
      rec = record({ ["select-window"] = bad(fixture("stderr_missing_pane")) })
      local res, err = tmux.focus({ pane = "%99" })
      expect.equality({ res, err.id, err.cmd }, { nil, "backend_error", "select-window" })
      expect.equality(err.msg, "tmux exited with 1: can't find pane: %99")
    end)
  end)
end)
