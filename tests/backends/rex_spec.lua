-- The fixtures in tests/fixtures/rex follow the shapes a live rex 0.0.1793377904-ge6592f (Rex Beta build 1696) printed
-- in D3. What is still unverified is listed in UNVERIFIED.txt there.
local backend = require("sidekick-ultra.backend")
local exec = require("sidekick-ultra.exec")
local fake = require("tests.helpers.fake")
local rex = require("sidekick-ultra.backends.rex")
local tools = require("sidekick-ultra.tools")

local expect = MiniTest.expect

local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/rex/"
local SID = "session:aaaa"
local SECRET = "SECRET-TOKEN-xyz"

---@param name string
---@return string
local function fixture(name)
  return table.concat(vim.fn.readfile(FIXTURES .. name .. ".json"), "\n")
end

---A process fixture whose foreground pid is this nvim, so `nvim_get_proc` finds it.
---@param name string
---@param patch? fun(fg: table)
---@return string
local function live(name, patch)
  local data = vim.json.decode(fixture(name))
  data.foreground.pid = (fake.self_proc())
  if patch then
    patch(data.foreground)
  end
  return vim.json.encode(data)
end

---@param stdout string
---@return table
local function ok(stdout)
  return { code = 0, stdout = stdout, stderr = "" }
end

---Replace `exec.run`. `routes` maps the arguments after the global flags (joined by spaces), or `ps` for a `ps` call,
---to a result table, a fixture-text string, or a function(call number) returning either. A command without a route is recorded in
---`unexpected` and fails with exit 97.
---@param routes table<string, table|string|fun(n: integer): table|string>
local function record(routes)
  local rec = { calls = {}, subs = {}, unexpected = {}, orig = exec.run }
  local counts = {}
  exec.run = function(argv, opts)
    table.insert(rec.calls, { argv = argv, opts = opts })
    local first = argv[3] == "-S" and 5 or 3
    local sub = argv[1] == "ps" and { "ps" } or vim.list_slice(argv, first)
    table.insert(rec.subs, sub)
    local key = table.concat(sub, " ")
    counts[key] = (counts[key] or 0) + 1
    local route = routes[key]
    if type(route) == "function" then
      route = route(counts[key])
    end
    if route == nil then
      table.insert(rec.unexpected, key)
      return { code = 97, stdout = "", stderr = "unexpected command" }
    end
    return type(route) == "string" and ok(route) or route
  end
  function rec.restore()
    exec.run = rec.orig
  end
  return rec
end

local STATUS = "block call -s session:aaaa -b block:a2 program_status"

describe("rex backend", function()
  local rec, dir, bin
  local env = {}

  ---@param rex_opts table the `rex` options besides `enabled`
  local function setup(rex_opts)
    fake.reset(
      { claude = { cmd = fake.INSTALLED }, codex = { cmd = fake.INSTALLED } },
      { rex = vim.tbl_extend("force", { enabled = false }, rex_opts) }
    )
  end

  local function a2()
    return fake.session(
      "rex",
      "claude",
      1,
      { id = "rex:block:a2", pid = 4242, session_id = SID, block_id = "block:a2" }
    )
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    bin = dir .. "/rex"
    vim.fn.writefile({ "#!/bin/sh" }, bin)
    vim.uv.fs_chmod(bin, 493)
    bin = vim.fn.exepath(bin)
    for _, var in ipairs({ "TERM_PROGRAM", "REX_SESSION", "REX_BLOCK", "PATH" }) do
      env[var] = vim.env[var]
    end
    env.bundle = rex.bundle_bin
    setup({ bin = bin })
  end)

  after_each(function()
    if rec then
      rec.restore()
      expect.equality(rec.unexpected, {})
      rec = nil
    end
    for _, var in ipairs({ "TERM_PROGRAM", "REX_SESSION", "REX_BLOCK", "PATH" }) do
      vim.env[var] = env[var]
    end
    rex.bundle_bin = env.bundle
    vim.fn.delete(dir, "rf")
  end)

  it("satisfies the backend contract", function()
    expect.equality(backend.check(rex), true)
    expect.equality(rex.name, "rex")
  end)

  describe("available", function()
    it("prefers the configured binary and reports the option as the source", function()
      expect.equality({ rex.available() }, { true, bin, "option" })
    end)

    it("is unavailable when the configured binary is missing, without trying PATH or the bundle", function()
      setup({ bin = dir .. "/missing" })
      expect.equality({ rex.available() }, { false })
    end)

    it("falls back to PATH, then to the bundle path when it is executable", function()
      setup({})
      vim.env.PATH = dir
      expect.equality({ rex.available() }, { true, bin, "PATH" })

      vim.env.PATH = "/nonexistent-sku-path"
      rex.bundle_bin = bin
      expect.equality({ rex.available() }, { true, bin, "bundle" })

      rex.bundle_bin = dir .. "/missing"
      expect.equality({ rex.available() }, { false })
    end)
  end)

  describe("inside", function()
    local function inside(term, session_id, block_id)
      vim.env.TERM_PROGRAM, vim.env.REX_SESSION, vim.env.REX_BLOCK = term, session_id, block_id
      return rex.inside()
    end

    it("needs TERM_PROGRAM=rex with REX_SESSION and REX_BLOCK set", function()
      expect.equality(inside("rex", SID, "block:a1"), true)
      expect.equality(inside("herdr", SID, "block:a1"), false)
      expect.equality(inside(nil, SID, "block:a1"), false)
      expect.equality(inside("rex", nil, "block:a1"), false)
      expect.equality(inside("rex", SID, nil), false)
      expect.equality(inside("rex", "", "block:a1"), false)
      expect.equality(inside("rex", SID, ""), false)
    end)
  end)

  describe("command line", function()
    it("starts every call with the binary and --autostart=false, and no -S by default", function()
      rec = record({ ["ls --json"] = fixture("ls_empty") })
      rex.list(tools.all())
      expect.equality(rec.calls[1].argv, { bin, "--autostart=false", "ls", "--json" })
    end)

    it("passes -S <server> before the subcommand when rex.server is set", function()
      setup({ bin = bin, server = "unix:///tmp/sku.sock" })
      rec = record({ ["ls --json"] = fixture("ls_empty") })
      rex.list(tools.all())
      expect.equality(rec.calls[1].argv, { bin, "--autostart=false", "-S", "unix:///tmp/sku.sock", "ls", "--json" })
    end)

    it("lists nothing, without an error, when `ls` finds no server (exit 4)", function()
      rec = record({ ["ls --json"] = { code = 4, stdout = "", stderr = "rex server is not running" } })
      local list, err = rex.list(tools.all())
      expect.equality({ list, err }, { {} })
      expect.equality(#rec.subs, 1)
    end)

    it("still reports exit 4 on a later step as backend_error", function()
      rec = record({
        ["ls --json"] = fixture("ls"),
        ["api call -s session:aaaa session.view"] = { code = 4, stdout = "", stderr = "rex server is not running" },
      })
      local list, err = rex.list(tools.all())
      expect.equality(list, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "session.view", 4 })
    end)

    it("fails with backend_error and runs nothing when the binary cannot be found", function()
      setup({ bin = dir .. "/missing" })
      rec = record({})
      local list, err = rex.list(tools.all())
      expect.equality(list, nil)
      expect.equality({ err.id, err.backend }, { "backend_error", "rex" })
      expect.equality(rec.calls, {})
    end)
  end)

  describe("list", function()
    local function routes()
      return {
        ["ls --json"] = fixture("ls"),
        ["api call -s session:aaaa session.view"] = fixture("view_a"),
        ["api call -s session:bbbb session.view"] = fixture("view_b"),
        ["block call -s session:aaaa -b block:a1 process"] = live("process_shell"),
        ["block call -s session:aaaa -b block:a2 process"] = live("process_claude"),
        ["block call -s session:aaaa -b block:a3 process"] = fixture("process_none"),
        ["block call -s session:bbbb -b block:b1 process"] = live("process_codex"),
      }
    end

    it("keeps the blocks whose foreground matches a tool, matching argv0 first and the name second", function()
      rec = record(routes())
      local pid, name = fake.self_proc()
      local list, err = rex.list(tools.all())
      expect.equality(err, nil)
      expect.equality(list, {
        {
          id = "rex:block:a2",
          backend = "rex",
          tool = "claude",
          cwd = "/tmp/sku-proj-a",
          pid = pid,
          proc_name = name,
          session_id = SID,
          block_id = "block:a2",
        },
        {
          id = "rex:block:b1",
          backend = "rex",
          tool = "codex",
          cwd = "/tmp/sku-proj-b",
          pid = pid,
          proc_name = name,
          session_id = "session:bbbb",
          block_id = "block:b1",
        },
      })
    end)

    it("discovers every block of a layer, not only its first", function()
      local r = routes()
      r["api call -s session:aaaa session.view"] = fixture("view_split")
      r["block call -s session:aaaa -b block:a4 process"] = live("process_claude")
      rec = record(r)
      local list, err = rex.list(tools.all())
      expect.equality(err, nil)
      expect.equality(
        vim.tbl_map(function(session)
          return session.id
        end, list),
        { "rex:block:a4", "rex:block:b1" }
      )
    end)

    it("reads each session and each block once", function()
      rec = record(routes())
      rex.list(tools.all())
      expect.equality(#rec.subs, 1 + 2 + 4)
    end)

    it("gives no session for an empty rex or when no tool is configured", function()
      rec = record({ ["ls --json"] = fixture("ls_empty") })
      expect.equality(rex.list(tools.all()), {})
      rec.restore()
      rec = record(routes())
      expect.equality(rex.list({}), {})
    end)

    it("skips a matching block whose pid this nvim cannot see", function()
      local r = routes()
      r["block call -s session:aaaa -b block:a2 process"] = live("process_claude", function(fg)
        fg.pid = 99999999
      end)
      rec = record(r)
      local list = rex.list(tools.all())
      expect.equality(
        vim.tbl_map(function(s)
          return s.id
        end, list),
        { "rex:block:b1" }
      )
    end)

    it("reports a matching block without a working directory", function()
      local r = routes()
      r["block call -s session:aaaa -b block:a2 process"] = live("process_claude", function(fg)
        fg.cwd = nil
      end)
      rec = record(r)
      local list, err = rex.list(tools.all())
      expect.equality(list, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "process" })
    end)

    it("maps a non-zero exit of any step to backend_error with its exit code", function()
      for step, label in pairs({
        ["ls --json"] = "ls",
        ["api call -s session:aaaa session.view"] = "session.view",
        ["block call -s session:aaaa -b block:a2 process"] = "process",
      }) do
        local r = routes()
        r[step] = { code = 3, stdout = "", stderr = "target not found" }
        rec = record(r)
        local list, err = rex.list(tools.all())
        expect.equality(rec.unexpected, {})
        rec.restore()
        rec = nil
        expect.equality(list, nil)
        expect.equality({ err.id, err.backend, err.cmd, err.code }, { "backend_error", "rex", label, 3 })
      end
    end)

    it("maps malformed responses to backend_error", function()
      local cases = {
        { "ls --json", "not json" },
        { "ls --json", '{"sessions":{"a":1}}' },
        { "ls --json", '{"sessions":[{"label":"x"}]}' },
        { "api call -s session:aaaa session.view", '{"windows":"x"}' },
        { "api call -s session:aaaa session.view", '{"windows":[{"layers":[{"blocks":[{"label":"x"}]}]}]}' },
        { "block call -s session:aaaa -b block:a1 process", fixture("process_bad") },
        { "block call -s session:aaaa -b block:a1 process", '"x"' },
      }
      for _, case in ipairs(cases) do
        local r = routes()
        r[case[1]] = case[2]
        rec = record(r)
        local list, err = rex.list(tools.all())
        expect.equality(rec.unexpected, {})
        rec.restore()
        rec = nil
        expect.equality(list, nil)
        expect.equality({ err.id, err.backend }, { "backend_error", "rex" })
      end
    end)
  end)

  -- A tool installed as a node or python script runs as its interpreter until it sets its own title: `pi` is a sh
  -- launcher that execs a `#!/usr/bin/env node` script, so for a while rex reports the foreground as node. The shape
  -- follows process_codex.json, a live reading of a node script whose title was set: argv0 "node", name the title.
  -- Before the title is set the name is a guess (name "node"), not a rex reading (UNVERIFIED.txt).
  describe("list for a script tool", function()
    local A2 = "block call -s session:aaaa -b block:a2 process"

    before_each(function()
      fake.reset(
        { claude = { cmd = fake.INSTALLED }, pi = { cmd = fake.INSTALLED } },
        { rex = { enabled = false, bin = bin } }
      )
    end)

    ---Routes where block a2's foreground is `fg` (pid this nvim) and `ps` answers `ps_route`.
    ---@param fg table
    ---@param ps_route table|string|fun(n: integer): table|string
    local function node_routes(fg, ps_route)
      return {
        ["ls --json"] = '{"sessions":[{"session_id":"session:aaaa","label":"work"}]}',
        ["api call -s session:aaaa session.view"] = fixture("view_a"),
        [A2] = live("process_claude", function(f)
          f.name, f.argv0 = fg.name, fg.argv0
        end),
        ["block call -s session:aaaa -b block:a1 process"] = live("process_shell"),
        ["block call -s session:aaaa -b block:a3 process"] = fixture("process_none"),
        ps = ps_route,
      }
    end

    ---@param line string a `ps` command line
    ---@return string[] ids
    local function listed(line)
      if rec then
        rec.restore()
      end
      rec = record(node_routes({ name = "node", argv0 = "node" }, line .. "\n"))
      local list, err = rex.list(tools.all())
      expect.equality(err, nil)
      expect.equality(vim.inspect({ list, rec.calls }):find(SECRET, 1, true), nil)
      return vim.tbl_map(function(s)
        return s.tool
      end, list)
    end

    it("finds a node tool by its script name, with one ps call, and records the interpreter's process", function()
      rec = record(node_routes({ name = "node", argv0 = "node" }, "node /x/bin/pi\n"))
      local pid, name = fake.self_proc()
      local list, err = rex.list(tools.all())
      expect.equality(err, nil)
      expect.equality(list, {
        {
          id = "rex:block:a2",
          backend = "rex",
          tool = "pi",
          cwd = "/tmp/sku-proj-a",
          pid = pid,
          proc_name = name,
          session_id = SID,
          block_id = "block:a2",
        },
      })
      local ps = vim.tbl_filter(function(call)
        return call.argv[1] == "ps"
      end, rec.calls)
      expect.equality(#ps, 1)
      expect.equality(ps[1].argv, { "ps", "-ww", "-o", "args=", "-p", tostring(pid) })
      expect.equality({ ps[1].opts.backend, ps[1].opts.cmd }, { "rex", "ps" })
    end)

    it("reads the interpreter from argv0 when the name is something else", function()
      rec = record(node_routes({ name = "22.1.0", argv0 = "/usr/local/bin/node" }, "node /x/bin/pi\n"))
      local list = rex.list(tools.all())
      expect.equality(#list, 1)
      expect.equality(list[1].tool, "pi")
    end)

    it("runs ps only for an interpreter", function()
      rec = record(node_routes({ name = "2.1.308", argv0 = "claude" }, "unused"))
      rex.list(tools.all())
      for _, sub in ipairs(rec.subs) do
        expect.equality(sub[1] == "ps", false)
      end
    end)

    it("keeps a block whose script is no tool, or that runs code, out of the list", function()
      expect.equality(listed("node /x/bin/other"), {})
      expect.equality(listed("node -e " .. SECRET), {})
      expect.equality(listed("python3 -c " .. SECRET), {})
    end)

    it("still matches a tool by its argv0 or name before any ps call", function()
      rec = record(node_routes({ name = "node", argv0 = "pi" }, { code = 2, stdout = "", stderr = "must not run" }))
      local list, err = rex.list(tools.all())
      expect.equality(err, nil)
      expect.equality(#list, 1)
      expect.equality(list[1].tool, "pi")
    end)

    it("skips a process that ended before ps ran", function()
      rec = record(node_routes({ name = "node", argv0 = "node" }, { code = 1, stdout = "", stderr = "" }))
      expect.equality(rex.list(tools.all()), {})
    end)

    it("maps a failing ps to backend_error without its stdout", function()
      local pid = fake.self_proc()
      rec = record(node_routes({ name = "node", argv0 = "node" }, {
        code = 3,
        stdout = "node /x/bin/pi --api-key " .. SECRET .. "\n",
        stderr = "ps: boom\nsecond\n",
      }))
      local list, err = rex.list(tools.all())
      expect.equality(list, nil)
      expect.equality({ err.id, err.backend, err.cmd, err.code }, { "backend_error", "rex", "ps", 3 })
      expect.equality(err.msg, ("ps exited with 3 for pid %d: ps: boom"):format(pid))
      expect.equality(vim.inspect({ err, rec.calls }):find(SECRET, 1, true), nil)
    end)

    it("is the exec error itself when ps cannot be spawned", function()
      rec = record(node_routes({ name = "node", argv0 = "node" }, "unused"))
      local routed = exec.run
      exec.run = function(argv, opts)
        if argv[1] == "ps" then
          return nil, require("sidekick-ultra.errors").new("backend_error", "cannot run ps: boom", opts)
        end
        return routed(argv, opts)
      end
      local list, err = rex.list(tools.all())
      expect.equality(
        { list, err.id, err.backend, err.cmd, err.msg },
        { nil, "backend_error", "rex", "ps", "cannot run ps: boom" }
      )
    end)

    -- Every command line below holds SECRET; nothing the backend returns or records may hold it.
    it("never lets a secret in the command line reach a session or a call", function()
      local cases = {
        { "node /x/bin/pi --api-key " .. SECRET, { "pi" } },
        { "node --require " .. SECRET .. " /x/bin/pi", { "pi" } },
        { 'node -e "' .. SECRET .. '"', {} },
        { 'node -pe "/x/' .. SECRET .. '/pi"', {} },
        { "node - /x/" .. SECRET .. "/pi", {} },
        { "python3 -m aider --token " .. SECRET, {} },
      }
      for _, case in ipairs(cases) do
        expect.equality({ case[1], listed(case[1]) }, { case[1], case[2] })
      end
      expect.equality(vim.fn.execute("messages"):find(SECRET, 1, true), nil)
    end)
  end)

  describe("start", function()
    local claude, opts, new_process, split_head, split_key
    before_each(function()
      claude = vim.tbl_extend("force", tools.get("claude"), { cmd = { "claude", "--resume" } })
      opts = { cwd = "/tmp/sku-proj-a", env = {} }
      new_process = "block call -s session:aaaa -b block:new1 process"
      split_head = "split -s session:aaaa -b block:a1 --split=right -c /tmp/sku-proj-a --focus=false --json --"
      split_key = split_head .. " claude --resume"
      vim.env.TERM_PROGRAM, vim.env.REX_SESSION, vim.env.REX_BLOCK = "rex", SID, "block:a1"
    end)

    it("splits right of nvim's own block by id, unfocused, with the cwd and the tool command", function()
      rec = record({ [split_key] = fixture("split"), [new_process] = live("process_claude") })
      local session, err = rex.start(claude, opts)
      expect.equality(err, nil)
      expect.equality(rec.subs[1], {
        "split",
        "-s",
        SID,
        "-b",
        "block:a1",
        "--split=right",
        "-c",
        "/tmp/sku-proj-a",
        "--focus=false",
        "--json",
        "--",
        "claude",
        "--resume",
      })
      local pid, name = fake.self_proc()
      expect.equality(session, {
        id = "rex:block:new1",
        backend = "rex",
        tool = "claude",
        cwd = "/tmp/sku-proj-a",
        pid = pid,
        proc_name = name,
        session_id = SID,
        block_id = "block:new1",
      })
    end)

    it("puts a non-empty tool env in front of the command as /usr/bin/env K=V, keys sorted", function()
      opts.env = { SKU_B = "2", SKU_A = "1" }
      rec = record({
        [split_head .. " /usr/bin/env SKU_A=1 SKU_B=2 claude --resume"] = fixture("split"),
        [new_process] = live("process_claude"),
      })
      local session, err = rex.start(claude, opts)
      expect.equality(err, nil)
      expect.equality(session.id, "rex:block:new1")
    end)

    it("records the foreground at that moment, even before the tool runs, with its nvim_get_proc name", function()
      rec = record({ [split_key] = fixture("split"), [new_process] = live("process_shell") })
      local pid, name = fake.self_proc()
      local session, err = rex.start(claude, opts)
      expect.equality(err, nil)
      expect.equality(
        { session.id, session.tool, session.pid, session.proc_name },
        { "rex:block:new1", "claude", pid, name }
      )
      expect.equality(#rec.subs, 2)
    end)

    it("fails with backend_error when the new block has no foreground or the pid is not visible to nvim", function()
      rec = record({ [split_key] = fixture("split"), [new_process] = fixture("process_none") })
      local session, err = rex.start(claude, opts)
      expect.equality(session, nil)
      expect.equality({ err.id, err.backend, err.cmd }, { "backend_error", "rex", "split" })
      rec.restore()
      rec = record({
        [split_key] = fixture("split"),
        [new_process] = live("process_shell", function(fg)
          fg.pid = 99999999
        end),
      })
      session, err = rex.start(claude, opts)
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "split" })
    end)

    it("maps a failing split to backend_error and reads nothing else", function()
      rec = record({ [split_key] = { code = 3, stdout = "", stderr = "target not found" } })
      local session, err = rex.start(claude, opts)
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "split", 3 })
      expect.equality(#rec.subs, 1)
    end)

    it("maps a split response without a block id to backend_error", function()
      rec = record({ [split_key] = '{"block_ids":[]}' })
      local session, err = rex.start(claude, opts)
      expect.equality(session, nil)
      expect.equality({ err.id, err.cmd }, { "backend_error", "split" })
    end)
  end)

  describe("send", function()
    local function routes(status)
      return {
        [STATUS] = status,
        ["send -s session:aaaa -b block:a2 -- hello\n"] = "",
        ["send -s session:aaaa -b block:a2 -- --help\n"] = "",
        ["send -s session:aaaa -b block:a2 -- a b\nc"] = "",
      }
    end

    it("reads the state, then sends the text as one argv element after --", function()
      rec = record(routes(fixture("status_working")))
      expect.equality(rex.send(a2(), "hello\n"), true)
      expect.equality(rec.subs[1], { "block", "call", "-s", SID, "-b", "block:a2", "program_status" })
      expect.equality(rec.subs[2], { "send", "-s", SID, "-b", "block:a2", "--", "hello\n" })
      expect.equality(#rec.subs, 2)
      expect.equality(rec.calls[2].opts.stdin, nil)
    end)

    it("keeps an option-shaped or multi-line text as a single element", function()
      rec = record(routes(fixture("status_empty")))
      expect.equality(rex.send(a2(), "--help\n"), true)
      expect.equality(rex.send(a2(), "a b\nc"), true)
      expect.equality(rec.subs[2][#rec.subs[2]], "--help\n")
      expect.equality(rec.subs[4][#rec.subs[4]], "a b\nc")
    end)

    it("treats an absent or empty record list as not blocked", function()
      rec = record(routes("{}"))
      expect.equality(rex.send(a2(), "hello\n"), true)
    end)

    it("sends nothing and returns true for empty text", function()
      rec = record({})
      expect.equality(rex.send(a2(), ""), true)
      expect.equality(rec.calls, {})
    end)

    it("refuses with session_blocked when a blocked record is owned by the session's pid, and sends nothing", function()
      rec = record(routes(fixture("status_blocked")))
      local res, err = rex.send(a2(), "hello\n")
      expect.equality(res, nil)
      expect.equality(err.id, "session_blocked")
      expect.equality(#rec.subs, 1)
    end)

    it("ignores a blocked record owned by another process", function()
      rec = record(routes(fixture("status_blocked_other")))
      expect.equality(rex.send(a2(), "hello\n"), true)
      expect.equality(#rec.subs, 2)
    end)

    it("refuses with status_unreadable when the state read fails or is ambiguous, and sends nothing", function()
      local cases = {
        { code = 4, stdout = "", stderr = "rex server is not running" },
        { code = 3, stdout = "", stderr = "block not found" },
        ok("not json"),
        ok(""),
        ok('"blocked"'),
        ok(fixture("status_bad")),
        ok('{"records":[{"state":5}]}'),
        ok('{"records":["blocked"]}'),
      }
      for _, case in ipairs(cases) do
        rec = record(routes(case))
        local res, err = rex.send(a2(), "hello\n")
        local count = #rec.subs
        expect.equality(rec.unexpected, {})
        rec.restore()
        rec = nil
        expect.equality(res, nil)
        expect.equality(err.id, "status_unreadable")
        expect.equality(count, 1)
      end
    end)

    it("maps a failing send to backend_error", function()
      local r = routes(fixture("status_working"))
      r["send -s session:aaaa -b block:a2 -- hello\n"] = { code = 3, stdout = "", stderr = "block not found" }
      rec = record(r)
      local res, err = rex.send(a2(), "hello\n")
      expect.equality(res, nil)
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "send", 3 })
    end)
  end)

  describe("submit and focus", function()
    it("submit presses enter in the block", function()
      rec = record({ ["send-key -s session:aaaa -b block:a2 enter"] = "" })
      expect.equality(rex.submit(a2()), true)
      expect.equality(rec.subs, { { "send-key", "-s", SID, "-b", "block:a2", "enter" } })
    end)

    it("focus targets the block by id", function()
      rec = record({ ["focus -s session:aaaa block:a2"] = "" })
      expect.equality(rex.focus(a2()), true)
      expect.equality(rec.subs, { { "focus", "-s", SID, "block:a2" } })
    end)

    it("map failures to backend_error", function()
      rec = record({
        ["send-key -s session:aaaa -b block:a2 enter"] = { code = 3, stdout = "", stderr = "block not found" },
        ["focus -s session:aaaa block:a2"] = { code = 4, stdout = "", stderr = "rex server is not running" },
      })
      local _, err = rex.submit(a2())
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "send-key", 3 })
      _, err = rex.focus(a2())
      expect.equality({ err.id, err.cmd, err.code }, { "backend_error", "focus", 4 })
    end)
  end)
end)
