-- The fixtures in tests/fixtures/tmux follow the shapes a tmux 3.8 probe printed in D8. What is still unverified is
-- listed in UNVERIFIED.txt there. Every tmux call goes through the exec seam; no spec runs tmux.
local backend = require("sidekick-ultra.backend")
local exec = require("sidekick-ultra.exec")
local fake = require("tests.helpers.fake")
local registry = require("sidekick-ultra.registry")
local tmux = require("sidekick-ultra.backends.tmux")
local tools = require("sidekick-ultra.tools")

local expect = MiniTest.expect

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/tmux/"
local LIST_FORMAT = "#{pane_id}\t#{pane_pid}\t#{pane_current_path}\t#{session_name}\t#{window_id}\t#{pane_dead}"
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

---Replace `exec.run`. `routes` maps the subcommand (the first argument after an optional `-S <socket>`) to a result
---table, a fixture-text string, or a function(call number) returning either. A subcommand without a route is recorded
---in `unexpected` and fails with exit 97. `calls[i]` is `{ argv, opts }`.
---@param routes table<string, table|string|fun(n: integer): table|string>
local function record(routes)
  local rec = { calls = {}, unexpected = {}, orig = exec.run }
  local counts = {}
  exec.run = function(argv, opts)
    table.insert(rec.calls, { argv = argv, opts = opts })
    local sub = argv[2] == "-S" and argv[4] or argv[2]
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

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for _, var in ipairs(VARS) do
      env[var] = vim.env[var]
    end
    setup()
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
  end)

  describe("available", function()
    it("is the tmux found on PATH, with PATH as its source", function()
      local bin = dir .. "/tmux"
      vim.fn.writefile({ "#!/bin/sh" }, bin)
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
      expect.equality(#rec.calls, 5)
    end)

    it("maps a non-zero exit to backend_error carrying the first stderr line", function()
      rec = record({ ["send-keys"] = bad(fixture("stderr_missing_pane") .. "second line\n") })
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
      restore_procs = fake_procs(TREE)
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

    it("skips a dead pane even when its old process tree still matches", function()
      rec = record({ ["list-panes"] = fixture("list_panes") })
      restore_procs = fake_procs(TREE)
      local ids = vim.tbl_map(function(s)
        return s.id
      end, tmux.list(tools.all()))
      expect.equality(vim.tbl_contains(ids, "tmux:%3"), false)
    end)

    it("lists no pane for a tool that is not configured", function()
      rec = record({ ["list-panes"] = fixture("list_panes") })
      restore_procs = fake_procs(TREE)
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
      restore_procs = fake_procs({
        [58100] = { name = "zsh", kids = { 1, 2, 3 } },
        [1] = { name = "bash", kids = { 11 } },
        [11] = { name = "node", kids = { 111 } },
        [111] = { name = "claude" },
        [2] = { name = "node", kids = { 22 } },
        [22] = { name = "codex" },
        [3] = { name = "bash", kids = { 33 } },
        [33] = { name = "node", kids = { 333 } },
        [333] = { name = "claude" },
      })
      local list = tmux.list(tools.all())
      expect.equality(#list, 1)
      expect.equality({ list[1].tool, list[1].pid, list[1].proc_name }, { "codex", 22, "codex" })
    end)

    it("matches the pane's own root process", function()
      rec = record({ ["list-panes"] = fixture("list_panes") })
      restore_procs = fake_procs({ [58200] = { name = "codex" } })
      local list = tmux.list(tools.all())
      expect.equality({ list[1].id, list[1].pid }, { "tmux:%2", 58200 })
    end)

    it("reads each process once, so a cycle ends, and skips an unreadable process", function()
      rec = record({ ["list-panes"] = fixture("list_panes") })
      local procs = {
        [58100] = { name = "zsh", kids = { 58100, 7, 8 } },
        [8] = { name = "claude", kids = { 58100 } },
      }
      local visits
      restore_procs, visits = fake_procs(procs)
      local list = tmux.list(tools.all())
      expect.equality({ #list, list[1].pid }, { 1, 8 })
      expect.equality(visits[58100], 1)
      rec.restore()
      -- No tool anywhere: the walk still ends, having read each process once.
      rec = record({ ["list-panes"] = fixture("list_panes") })
      restore_procs()
      procs[8].name = "sh"
      restore_procs, visits = fake_procs(procs)
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
      restore_procs = fake_procs(TREE)
      local list = tmux.list({ claude = claude })
      expect.equality(
        vim.tbl_filter(function(proc)
          return proc.pid >= 58100 and proc.pid <= 58101
        end, seen),
        { { pid = 58100, cmd = "zsh" }, { pid = 58101, cmd = "claude" } }
      )
      expect.equality({ #list, list[1].pid, list[1].proc_name }, { 1, 58101, "claude" })
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
      for _, name in ipairs({ "list_panes_bad_fields", "list_panes_bad_id" }) do
        rec = record({ ["list-panes"] = fixture(name) })
        local list, err = tmux.list(tools.all())
        expect.equality({ list, err.id }, { nil, "backend_error" })
        rec.restore()
      end
      rec = nil
    end)

    it("fails when a matched pane has no working directory", function()
      rec = record({ ["list-panes"] = fixture("list_panes_no_cwd") })
      restore_procs = fake_procs({ [58100] = { name = "claude" } })
      local list, err = tmux.list(tools.all())
      expect.equality({ list, err.id }, { nil, "backend_error" })
      expect.equality(err.msg:find("%1", 1, true) ~= nil, true)
    end)
  end)

  describe("start", function()
    local OPTS_ENV = {}

    ---A start whose new pane's root process is this nvim (a real pid that is not a tool).
    local function split_route()
      local pid = fake.self_proc()
      return "%5\t" .. pid .. "\n"
    end

    before_each(function()
      vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/t.sock,100,0", "%0"
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
      local pid, name = fake.self_proc()
      local session = tmux.start(tools.get("claude"), { cwd = "/work/dir", env = OPTS_ENV })
      expect.equality(session, {
        id = "tmux:%5",
        backend = "tmux",
        tool = "claude",
        cwd = "/work/dir",
        pid = pid,
        proc_name = name,
        pane = "%5",
      })
      expect.equality(registry.is_running(session), true)
      expect.equality(#rec.calls, 1)
    end)

    it("records the tool's own process when the tree already runs it", function()
      rec = record({ ["split-window"] = fixture("split_window") })
      restore_procs = fake_procs({ [58500] = { name = "zsh", kids = { 58501 } }, [58501] = { name = "claude" } })
      local session = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session.pid, session.proc_name }, { 58501, "claude" })
      rec.restore()
      -- Only the started tool counts: a codex in the tree is not this session.
      rec = record({ ["split-window"] = fixture("split_window") })
      restore_procs()
      restore_procs = fake_procs({ [58500] = { name = "codex" } })
      session = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session.pid, session.proc_name }, { 58500, "codex" })
    end)

    it("returns the tmux error and creates nothing else when split-window fails", function()
      rec = record({ ["split-window"] = bad("no space for new pane\n") })
      local session, err = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session, err.id, err.cmd }, { nil, "backend_error", "split-window" })
      expect.equality(#rec.calls, 1)
    end)

    it("fails when tmux prints no pane id", function()
      rec = record({ ["split-window"] = "\n" })
      local session, err = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session, err.id }, { nil, "backend_error" })
    end)

    it("fails, naming the pane left open, when its process is not visible to this nvim", function()
      rec = record({ ["split-window"] = "%5\t" .. (2 ^ 22 + 12345) .. "\n" })
      local session, err = tmux.start(tools.get("claude"), { cwd = "/w", env = OPTS_ENV })
      expect.equality({ session, err.id }, { nil, "backend_error" })
      expect.equality(err.msg:find("%5", 1, true) ~= nil and err.msg:find("left open", 1, true) ~= nil, true)
    end)
  end)

  describe("send", function()
    it(
      "loads the text from stdin into a named buffer, then pastes it raw into the pane and deletes the buffer",
      function()
        rec = record({ ["load-buffer"] = "", ["paste-buffer"] = "" })
        local text = "line one\nline two\n  indented"
        expect.equality(tmux.send({ pane = "%2" }, text), true)
        local load, paste = rec.argvs()[1], rec.argvs()[2]
        local buffer = load[4]
        expect.equality(buffer:match("^sku%-%d+%-%d+$") ~= nil, true)
        expect.equality(load, { "tmux", "load-buffer", "-b", buffer, "-" })
        expect.equality(paste, { "tmux", "paste-buffer", "-b", buffer, "-d", "-r", "-t", "%2" })
        expect.equality(rec.calls[1].opts.stdin, text)
        expect.equality(#rec.calls, 2)
      end
    )

    it("presses no Enter and sends no key", function()
      rec = record({ ["load-buffer"] = "", ["paste-buffer"] = "" })
      tmux.send({ pane = "%2" }, "hi")
      for _, argv in ipairs(rec.argvs()) do
        expect.equality(vim.tbl_contains(argv, "send-keys"), false)
        expect.equality(vim.tbl_contains(argv, "Enter"), false)
      end
    end)

    it("uses a different buffer for each send", function()
      rec = record({ ["load-buffer"] = "", ["paste-buffer"] = "" })
      tmux.send({ pane = "%2" }, "a")
      tmux.send({ pane = "%2" }, "b")
      expect.no_equality(rec.argvs()[1][4], rec.argvs()[3][4])
    end)

    it("sends nothing for an empty text", function()
      rec = record({})
      expect.equality(tmux.send({ pane = "%2" }, ""), true)
      expect.equality(rec.calls, {})
    end)

    it("stops when the buffer cannot be loaded, without pasting", function()
      rec = record({ ["load-buffer"] = bad("no server running\n") })
      local res, err = tmux.send({ pane = "%2" }, "x")
      expect.equality({ res, err.id, err.cmd }, { nil, "backend_error", "load-buffer" })
      expect.equality(#rec.calls, 1)
    end)

    it("deletes the buffer and reports the pane error when the paste fails", function()
      rec = record({
        ["load-buffer"] = "",
        ["paste-buffer"] = bad(fixture("stderr_missing_pane")),
        ["delete-buffer"] = "",
      })
      local res, err = tmux.send({ pane = "%99" }, "x")
      expect.equality({ res, err.id, err.cmd }, { nil, "backend_error", "paste-buffer" })
      expect.equality(err.msg, "tmux exited with 1: can't find pane: %99")
      local buffer = rec.argvs()[1][4]
      expect.equality(rec.argvs()[3], { "tmux", "delete-buffer", "-b", buffer })
    end)
  end)

  describe("submit", function()
    it("sends Enter to the pane", function()
      rec = record({ ["send-keys"] = "" })
      expect.equality(tmux.submit({ pane = "%2" }), true)
      expect.equality(rec.argvs(), { { "tmux", "send-keys", "-t", "%2", "Enter" } })
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
