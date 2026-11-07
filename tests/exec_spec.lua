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

  it("maps a non-zero exit to backend_error with its code and the first stderr line", function()
    local res, err = exec.check({ "/bin/sh", "-c", "echo first >&2; echo second >&2; exit 4" })
    expect.equality(res, nil)
    expect.equality({ err.id, err.code }, { "backend_error", 4 })
    expect.equality(err.msg:find("first", 1, true) ~= nil, true)
    expect.equality(err.msg:find("second", 1, true), nil)
  end)

  it("hands a caller the first stderr line of a failed check as data, and none for a run that failed to run", function()
    local _, err = exec.check({ "/bin/sh", "-c", "echo first >&2; echo second >&2; exit 4" })
    expect.equality({ err.code, err.stderr, err.msg }, { 4, "first", "/bin/sh exited with 4: first" })
    _, err = exec.check({ "/bin/sh", "-c", "exit 4" })
    expect.equality({ err.code, err.stderr, err.msg }, { 4, "", "/bin/sh exited with 4" })
    _, err = exec.check({ "/nonexistent/sku-binary" })
    expect.equality({ err.code, err.stderr }, { nil, nil })
  end)

  it("words a failed result under the head a caller gives it", function()
    local res = { code = 3, stdout = "x", stderr = "boom\nmore\n" }
    local err = exec.result_error({ "tool" }, res, "tool broke")
    expect.equality({ err.id, err.code, err.stderr, err.msg }, { "backend_error", 3, "boom", "tool broke: boom" })
  end)

  it("decodes JSON text, turning null into nil, and says when the text is not JSON", function()
    expect.equality({ exec.decode('{"a":null,"b":[1]}') }, { true, { b = { 1 } } })
    expect.equality((exec.decode("null")), true)
    expect.equality((exec.decode("not json")), false)
    expect.equality((exec.decode("")), false)
  end)

  it("words variables as K=V with the keys sorted, and puts them in front of a command after /usr/bin/env", function()
    local vars = { SKU_B = "2", SKU_A = "a=1" }
    expect.equality(exec.env_pairs(vars), { "SKU_A=a=1", "SKU_B=2" })
    expect.equality(exec.env_pairs({}), {})
    expect.equality(exec.env_prefix(vars), { "/usr/bin/env", "SKU_A=a=1", "SKU_B=2" })
    expect.equality(exec.env_prefix({}), {})
  end)

  it("keeps no output: no module holds what a command or a process line printed", function()
    local secret = require("tests.helpers.backend").SECRET
    -- Every backend and proc are loaded, so the scan below sees them in a narrowed run too.
    for _, name in ipairs(require("sidekick-ultra.backends").names()) do
      require("sidekick-ultra.backends." .. name)
    end
    local res = exec.run({ "/bin/sh", "-c", "echo " .. secret })
    expect.equality(res.stdout, secret .. "\n")
    -- A `ps` line with the secret goes through proc, which parses it.
    local orig = exec.run
    MiniTest.finally(function()
      exec.run = orig
    end)
    exec.run = function()
      return { code = 0, stdout = "node /x/bin/pi --api-key " .. secret .. "\n", stderr = "" }
    end
    local pi = {
      is_proc = function()
        return false
      end,
    }
    require("sidekick-ultra.proc").tool_of({ pi = pi }, 1, { "node" })
    for name, mod in pairs(package.loaded) do
      if type(name) == "string" and name:find("^sidekick%-ultra") then
        expect.equality({ name, vim.inspect(mod):find(secret, 1, true) }, { name, nil })
      end
    end
    expect.equality(vim.fn.execute("messages"):find(secret, 1, true), nil)
  end)

  it("maps a timeout to backend_error", function()
    local res, err = exec.run({ "/bin/sleep", "5" }, { timeout_ms = 100 })
    expect.equality(res, nil)
    expect.equality({ err.id, err.msg }, { "backend_error", "/bin/sleep timed out after 100 ms" })
  end)

  it("maps a timeout to backend_error when the child ignores SIGTERM and is killed with SIGKILL", function()
    local res, err = exec.run({ "/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 5" }, { timeout_ms = 100 })
    expect.equality(res, nil)
    expect.equality(err.id, "backend_error")
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

  it("maps invalid JSON and empty output to backend_error, and marks empty output", function()
    local _, err = exec.json({ "/bin/sh", "-c", "echo not-json" })
    expect.equality({ err.id, err.msg, err.empty }, { "backend_error", "/bin/sh printed invalid JSON", nil })
    _, err = exec.json({ "/bin/sh", "-c", "true" })
    expect.equality({ err.id, err.msg, err.empty }, { "backend_error", "/bin/sh printed invalid JSON", true })
    _, err = exec.json({ "/bin/sh", "-c", "echo '  '" })
    expect.equality(err.empty, true)
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
