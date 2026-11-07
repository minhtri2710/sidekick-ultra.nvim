local backend = require("sidekick-ultra.backend")
local backends = require("sidekick-ultra.backends")

local expect = MiniTest.expect

local DIR = vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))) .. "/../lua/sidekick-ultra/backends"

describe("backend table", function()
  it("lists exactly the backend modules, each of which satisfies the backend contract", function()
    local files = {}
    for file in vim.fs.dir(DIR) do
      if file ~= "init.lua" then
        table.insert(files, (file:gsub("%.lua$", "")))
      end
    end
    table.sort(files)
    local names = backends.names()
    table.sort(names)
    expect.equality(names, files)
    for _, name in ipairs(names) do
      local mod = require("sidekick-ultra.backends." .. name)
      expect.equality({ name, backend.check(mod) }, { name, true })
      expect.equality(mod.name, name)
    end
  end)
end)

describe("guard_send", function()
  local session = { id = "herdr:w1:p1", tool = "claude" }

  it("lets the send through when the session is not blocked", function()
    expect.equality(
      backend.guard_send(session, function()
        return false
      end),
      true
    )
  end)

  it("refuses a blocked session with session_blocked", function()
    local ok, err = backend.guard_send(session, function()
      return true
    end)
    expect.equality(ok, nil)
    expect.equality({ err.id, err.msg }, { "session_blocked", "claude (herdr:w1:p1) is blocked; nothing was sent" })
  end)

  it("refuses with status_unreadable, keeping the exit code, when the state cannot be read", function()
    local ok, err = backend.guard_send(session, function()
      return nil, { id = "backend_error", msg = "boom", code = 3 }
    end)
    expect.equality(ok, nil)
    expect.equality(
      { err.id, err.msg, err.code },
      { "status_unreadable", "cannot read the state of herdr:w1:p1: boom", 3 }
    )
  end)
end)
