local expect = MiniTest.expect

local root = vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))))

describe("test harness", function()
  it("resolves herdr and rex to the stubs", function()
    for _, name in ipairs({ "herdr", "rex" }) do
      expect.equality(vim.uv.fs_realpath(vim.fn.exepath(name)), vim.uv.fs_realpath(root .. "/tests/bin/" .. name))
    end
  end)

  it("makes a stub that is reached exit 97 and leave a marker in HOME", function()
    -- The run's own HOME carries the marker that fails the suite, so these deliberate calls use another one.
    local home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    for _, name in ipairs({ "herdr", "rex" }) do
      vim.fn.delete(home .. "/.sku-stub-reached")
      local res = require("sidekick-ultra.exec").run({ name, "anything" }, { env = { HOME = home } })
      expect.equality(res.code, 97)
      expect.equality(res.stderr:find("stub reached", 1, true) ~= nil, true)
      expect.equality(vim.uv.fs_stat(home .. "/.sku-stub-reached") ~= nil, true)
    end
    vim.fn.delete(home, "rf")
    expect.equality(vim.uv.fs_stat(vim.env.HOME .. "/.sku-stub-reached"), nil)
  end)

  it("runs with the mux environment cleared", function()
    for _, var in ipairs({
      "HERDR_ENV",
      "HERDR_PANE_ID",
      "HERDR_SOCKET_PATH",
      "REX_SERVER",
      "REX_BLOCK",
      "TERM_PROGRAM",
    }) do
      expect.equality(vim.env[var], nil)
    end
  end)

  it("aborts minit before any spec when the stubs are not first on PATH", function()
    local res = vim
      .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", root .. "/tests/minit.lua" }, {
        env = { PATH = "/usr/bin:/bin" },
        text = true,
        timeout = 20000,
      })
      :wait()
    expect.equality(res.code, 2)
    expect.equality(res.stderr:find("refusing to run", 1, true) ~= nil, true)
  end)
end)
