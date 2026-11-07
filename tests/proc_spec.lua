local exec = require("sidekick-ultra.exec")
local helper = require("tests.helpers.backend")
local proc = require("sidekick-ultra.proc")

local expect = MiniTest.expect

---A tool whose `is_proc` records every ProcInfo it is asked about and says yes to `cmd` only.
---@param seen table[]
---@param cmd? string
---@return sidekick_ultra.Tool
local function tool(seen, cmd)
  return {
    name = cmd or "none",
    is_proc = function(info)
      table.insert(seen, info)
      return info.cmd == cmd
    end,
  }
end

---@param seen table[]
---@return string[]
local function cmds(seen)
  return vim.tbl_map(function(info)
    return info.cmd
  end, seen)
end

describe("proc", function()
  local orig_run, ps_calls, ps_route

  ---@param route table|string the answer of `ps`: a result table, or its stdout
  local function ps(route)
    ps_route = route
  end

  before_each(function()
    orig_run, ps_calls, ps_route = exec.run, {}, nil
    exec.run = function(argv, opts)
      expect.equality(argv[1], "ps")
      table.insert(ps_calls, { argv = argv, opts = opts })
      return type(ps_route) == "string" and { code = 0, stdout = ps_route, stderr = "" } or ps_route
    end
  end)

  after_each(function()
    exec.run = orig_run
  end)

  describe("name", function()
    it("is the name nvim reads for a process, and nil for one it cannot see", function()
      local pid = vim.uv.os_getpid()
      expect.equality(proc.name(pid), vim.api.nvim_get_proc(pid).name)
      expect.equality(proc.name(2000000000), nil)
    end)
  end)

  describe("matches", function()
    it("calls is_proc with { pid, cmd }, and with no pid when the backend has none", function()
      local seen = {}
      local t = tool(seen, "claude")
      expect.equality(proc.matches(t, 7, "claude"), true)
      expect.equality(proc.matches(t, nil, "codex"), false)
      expect.equality(seen, { { pid = 7, cmd = "claude" }, { cmd = "codex" } })
    end)

    it("turns a throwing is_proc into a backend_error naming the tool, not an answer", function()
      local throwing = {
        name = "mine",
        is_proc = function()
          error("boom")
        end,
      }
      local matched, err = proc.matches(throwing, 7, "mine")
      expect.equality({ matched, err.id }, { nil, "backend_error" })
      expect.equality(err.msg:find("mine", 1, true) ~= nil and err.msg:find("boom", 1, true) ~= nil, true)
    end)

    it("never tests an empty name", function()
      local seen = {}
      local always = {
        is_proc = function()
          return true
        end,
      }
      expect.equality(proc.matches(always, 7, ""), false)
      expect.equality(proc.matches(tool(seen), 7, ""), false)
      expect.equality(seen, {})
    end)
  end)

  describe("find", function()
    it("tries the tools in name order, each against every word, so the first tool by name wins", function()
      local seen = {}
      local tools = { b = tool(seen, "x"), a = tool(seen, "y") }
      expect.equality(proc.find(tools, 1, { "x", "y" }), "a")
      expect.equality(cmds(seen), { "x", "y" })
    end)

    it("is nil when nothing matches", function()
      expect.equality(proc.find({ a = tool({}, "x") }, 1, { "y" }), nil)
    end)

    it("stops at a throwing is_proc with its error, in find and in tool_of", function()
      local throwing = {
        name = "mine",
        is_proc = function()
          error("boom")
        end,
      }
      local name, err = proc.find({ a = throwing }, 1, { "x" })
      expect.equality({ name, err.id }, { nil, "backend_error" })
      name, err = proc.tool_of({ a = throwing }, 1, { "x" })
      expect.equality({ name, err.id }, { nil, "backend_error" })
      ps("node /x/bin/pi\n")
      name, err = proc.tool_of({ a = throwing }, 1, { "node" })
      expect.equality({ name, err.id }, { nil, "backend_error" })
    end)
  end)

  describe("tool_of", function()
    it("tries the words in the order given and returns the first tool they satisfy", function()
      local seen = {}
      local tools = { claude = tool(seen, "claude") }
      expect.equality({ proc.tool_of(tools, 7, { "2.1.308", "claude" }) }, { "claude" })
      expect.equality(cmds(seen), { "2.1.308", "claude" })
      expect.equality(ps_calls, {})
    end)

    it("never tests an interpreter's own name, and reads no script when a word matched", function()
      local seen = {}
      local tools = { pi = tool(seen, "pi") }
      ps("unused")
      expect.equality({ proc.tool_of(tools, 7, { "node", "pi" }) }, { "pi" })
      expect.equality(seen, { { pid = 7, cmd = "pi" } })
      expect.equality(ps_calls, {})
    end)

    it("reads the script of an interpreter once, and tests only the script after the other words", function()
      local seen = {}
      local tools = { pi = tool(seen, "pi") }
      ps("/opt/bin/node /x/bin/pi --flag\n")
      expect.equality({ proc.tool_of(tools, 7, { "node", "22.1.0", "node" }) }, { "pi" })
      expect.equality(#ps_calls, 1)
      expect.equality(ps_calls[1].argv, { "ps", "-ww", "-o", "args=", "-p", "7" })
      expect.equality(seen, { { pid = 7, cmd = "22.1.0" }, { pid = 7, cmd = "pi" } })
    end)

    it("reads nothing, and finds nothing, when no tool is configured", function()
      ps("node /x/bin/pi\n")
      expect.equality({ proc.tool_of({}, 7, { "node" }) }, {})
      expect.equality(ps_calls, {})
    end)

    it("finds no tool for an interpreter that runs no script, or one that is not a tool", function()
      local tools = { pi = tool({}, "pi") }
      ps("node -e pi\n")
      expect.equality({ proc.tool_of(tools, 7, { "node" }) }, {})
      ps("node /x/bin/other pi\n")
      expect.equality({ proc.tool_of(tools, 7, { "node" }) }, {})
    end)

    it("skips a process that ended before ps ran", function()
      ps({ code = 1, stdout = "", stderr = "" })
      expect.equality({ proc.tool_of({ pi = tool({}, "pi") }, 7, { "node" }) }, {})
    end)

    it(
      "is a backend_error for any other ps failure, naming the pid, the exit code and the first stderr line",
      function()
        local tools = { pi = tool({}, "pi") }
        ps({ code = 3, stdout = "node /x/bin/pi --key " .. helper.SECRET .. "\n", stderr = "ps: boom\nsecond\n" })
        local name, err = proc.tool_of(tools, 7, { "node" })
        expect.equality(name, nil)
        expect.equality({ err.id, err.code }, { "backend_error", 3 })
        expect.equality(err.msg, "ps exited with 3 for pid 7: ps: boom")
        expect.equality(vim.inspect(err):find(helper.SECRET, 1, true), nil)
        ps({ code = 1, stdout = "x\n", stderr = "" })
        _, err = proc.tool_of(tools, 7, { "node" })
        expect.equality(err.msg, "ps exited with 1 for pid 7")
        -- Exit 1 means "gone" only when both streams are empty.
        ps({ code = 1, stdout = "", stderr = "ps: illegal option\n" })
        _, err = proc.tool_of(tools, 7, { "node" })
        expect.equality({ err.code, err.msg }, { 1, "ps exited with 1 for pid 7: ps: illegal option" })
        ps({ code = 0, stdout = "\n", stderr = "" })
        _, err = proc.tool_of(tools, 7, { "node" })
        expect.equality({ err.code, err.msg }, { 0, "ps printed nothing for pid 7" })
      end
    )

    it("is the exec error itself when ps cannot run", function()
      exec.run = function()
        return nil, { id = "backend_error", msg = "cannot run ps: boom" }
      end
      local _, err = proc.tool_of({ pi = tool({}, "pi") }, 7, { "node" })
      expect.equality(err.msg, "cannot run ps: boom")
    end)
  end)
end)
