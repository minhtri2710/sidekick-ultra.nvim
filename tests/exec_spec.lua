local exec = require("sidekick-ultra.exec")

local expect = MiniTest.expect

describe("exec", function()
  it("returns code, stdout and stderr", function()
    local res = exec.run({ "/bin/sh", "-c", "echo out; echo err >&2; exit 3" })
    expect.equality(res, { code = 3, stdout = "out\n", stderr = "err\n" })
  end)

  it("passes stdin", function()
    local res = exec.run({ "/bin/cat" }, { stdin = "hello" })
    expect.equality(res.stdout, "hello")
  end)

  it("maps a non-zero exit to backend_error with backend, cmd, code and the first stderr line", function()
    local res, err = exec.check(
      { "/bin/sh", "-c", "echo first >&2; echo second >&2; exit 4" },
      { backend = "herdr", cmd = "pane list" }
    )
    expect.equality(res, nil)
    expect.equality({ err.id, err.backend, err.cmd, err.code }, { "backend_error", "herdr", "pane list", 4 })
    expect.equality(err.msg:find("first", 1, true) ~= nil, true)
    expect.equality(err.msg:find("second", 1, true), nil)
  end)

  it("defaults the subcommand label to argv[2]", function()
    local _, err = exec.check({ "/bin/sh", "-c", "exit 1" })
    expect.equality(err.cmd, "-c")
  end)

  it("maps a timeout to backend_error", function()
    local res, err = exec.run({ "/bin/sleep", "5" }, { timeout_ms = 100, backend = "rex", cmd = "ls" })
    expect.equality(res, nil)
    expect.equality({ err.id, err.backend, err.cmd }, { "backend_error", "rex", "ls" })
  end)

  it("maps a timeout to backend_error when the child ignores SIGTERM and is killed with SIGKILL", function()
    local res, err = exec.run({ "/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 5" }, {
      timeout_ms = 100,
      backend = "rex",
      cmd = "ls",
    })
    expect.equality(res, nil)
    expect.equality({ err.id, err.backend, err.cmd }, { "backend_error", "rex", "ls" })
  end)

  it("maps a missing executable to backend_error", function()
    local res, err = exec.run({ "/nonexistent/sku-binary" })
    expect.equality(res, nil)
    expect.equality(err.id, "backend_error")
  end)

  it("decodes JSON output, turning null into nil", function()
    local data = exec.json({ "/bin/sh", "-c", [[echo '{"a":[1,2],"b":null}']] })
    expect.equality(data, { a = { 1, 2 } })
  end)

  it("maps invalid JSON and empty output to backend_error", function()
    local _, err = exec.json({ "/bin/sh", "-c", "echo not-json" }, { backend = "rex", cmd = "ls" })
    expect.equality({ err.id, err.backend, err.cmd }, { "backend_error", "rex", "ls" })
    _, err = exec.json({ "/bin/sh", "-c", "true" })
    expect.equality(err.id, "backend_error")
  end)

  it("maps a failing command to backend_error before decoding", function()
    local _, err = exec.json({ "/bin/sh", "-c", "echo '{}'; exit 2" })
    expect.equality({ err.id, err.code }, { "backend_error", 2 })
  end)

  it("lets specs replace run; check and json go through the replacement", function()
    local orig = exec.run
    local seen
    exec.run = function(argv)
      seen = argv
      return { code = 0, stdout = '{"ok":true}', stderr = "" }
    end
    local data = exec.json({ "fake", "sub" })
    exec.run = orig
    expect.equality(seen, { "fake", "sub" })
    expect.equality(data, { ok = true })
  end)
end)
