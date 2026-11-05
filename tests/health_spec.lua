local exec = require("sidekick-ultra.exec")
local fake = require("tests.helpers.fake")

local expect = MiniTest.expect

local NAMES = { "herdr", "rex", "tmux", "zellij" }

describe("health", function()
  local report, orig, loaded, orig_run, version_calls

  ---Run the check and return the reported `kind: message` lines.
  local function check()
    report = {}
    require("sidekick-ultra.health").check()
    return report
  end

  local function has(kind, needle)
    for _, line in ipairs(report) do
      if line.kind == kind and line.msg:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  ---The advice lines of the first reported line of `kind` whose message holds `needle`.
  local function advice(kind, needle)
    for _, line in ipairs(report) do
      if line.kind == kind and line.msg:find(needle, 1, true) then
        return table.concat(line.advice or {}, "\n")
      end
    end
  end

  before_each(function()
    orig = {}
    for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
      orig[kind] = vim.health[kind]
      vim.health[kind] = function(msg, hint)
        table.insert(report, { kind = kind, msg = msg, advice = hint })
      end
    end
    loaded = {}
    for _, name in ipairs(NAMES) do
      loaded[name] = package.loaded["sidekick-ultra.backends." .. name]
    end
    -- The version rows run `<bin> -V` / `--version` through the exec seam; nothing here runs a real binary.
    version_calls = {}
    orig_run = exec.run
    exec.run = function(argv)
      table.insert(version_calls, argv)
      return { code = 0, stdout = vim.fs.basename(argv[1]) .. " 9.9\n", stderr = "" }
    end
  end)
  after_each(function()
    for kind, fn in pairs(orig) do
      vim.health[kind] = fn
    end
    for _, name in ipairs(NAMES) do
      package.loaded["sidekick-ultra.backends." .. name] = loaded[name]
    end
    exec.run = orig_run
    vim.env.HERDR_SOCKET_PATH = nil
  end)

  it("reports the Neovim version", function()
    fake.reset()
    check()
    expect.equality(has("ok", "Neovim >= 0.11.2"), true)
  end)

  it("reports disabled backends without loading them", function()
    fake.reset()
    check()
    expect.equality(has("info", "herdr: disabled"), true)
    expect.equality(has("info", "rex: disabled"), true)
    expect.equality(has("info", "tmux: disabled"), true)
    expect.equality(has("info", "zellij: disabled"), true)
    expect.equality(version_calls, {})
  end)

  it("reports the binary path and where it came from, and start availability", function()
    local herdr = fake.backend("herdr", { is_inside = true })
    local rex = fake.backend("rex")
    rex.available = function()
      return true, "/opt/rex", "PATH"
    end
    package.loaded["sidekick-ultra.backends.herdr"] = herdr
    package.loaded["sidekick-ultra.backends.rex"] = rex
    fake.reset(nil, { herdr = { enabled = true }, rex = { enabled = true, server = "unix:///x" } })
    check()
    expect.equality(has("ok", "herdr: /fake/herdr (from fake)"), true)
    expect.equality(has("ok", "rex: /opt/rex (from PATH)"), true)
    expect.equality(has("info", "rex.server"), true)
    expect.equality(has("ok", "nvim runs inside herdr: start is available"), true)
  end)

  it("errors for an enabled backend whose binary is missing, and names env vars only", function()
    local herdr = fake.backend("herdr")
    herdr.available = function()
      return false
    end
    package.loaded["sidekick-ultra.backends.herdr"] = herdr
    package.loaded["sidekick-ultra.backends.rex"] = fake.backend("rex")
    vim.env.HERDR_SOCKET_PATH = "/secret/path/herdr.sock"
    fake.reset(nil, { herdr = { enabled = true }, rex = { enabled = true } })
    check()
    expect.equality(has("error", "herdr: binary not found"), true)
    expect.equality(has("info", "HERDR_SOCKET_PATH"), true)
    expect.equality(has("info", "/secret/path"), false)
    expect.equality(has("info", "rex: rex.server is not configured"), true)
    expect.equality(has("info", "start is unavailable"), true)
  end)

  it("names rex.bin and its value when the configured binary is missing", function()
    package.loaded["sidekick-ultra.backends.rex"] = nil
    fake.reset(nil, { rex = { enabled = true, bin = "/nonexistent/sku-rex" } })
    check()
    expect.equality(has("error", "rex.bin"), true)
    expect.equality(has("error", "/nonexistent/sku-rex"), true)
    expect.equality(has("error", "binary not found"), false)
    expect.equality(advice("error", "rex.bin"):find("Fix or remove `rex.bin`", 1, true) ~= nil, true)
  end)

  ---Fake tmux and zellij modules with a binary path and an inside state.
  local function muxes(tmux_inside, zellij_inside)
    for name, inside in pairs({ tmux = tmux_inside, zellij = zellij_inside }) do
      local b = fake.backend(name, { is_inside = inside })
      b.available = function()
        return true, "/opt/" .. name, "PATH"
      end
      -- The real tmux backend names its floor; a fake zellij has none, like the real one.
      b.MIN_VERSION = name == "tmux" and { 3, 7 } or nil
      package.loaded["sidekick-ultra.backends." .. name] = b
    end
  end

  it("reports the tmux and zellij binary, inside state and version through the exec seam", function()
    muxes(true, false)
    fake.reset(nil, { tmux = { enabled = true }, zellij = { enabled = true } })
    check()
    expect.equality(has("ok", "tmux: /opt/tmux (from PATH)"), true)
    expect.equality(has("ok", "zellij: /opt/zellij (from PATH)"), true)
    expect.equality(has("info", "tmux: nvim runs inside tmux"), true)
    expect.equality(has("info", "zellij: nvim does not run inside zellij"), true)
    expect.equality(has("info", "tmux: version 9.9"), true)
    expect.equality(has("info", "zellij: version 9.9"), true)
    expect.equality(version_calls, { { "/opt/tmux", "-V" }, { "/opt/zellij", "--version" } })
    expect.equality(has("ok", "nvim runs inside tmux: start is available"), true)
  end)

  it("drops only the leading tool name from the version line, so the row does not say it twice", function()
    muxes(false, false)
    local out = { ["/opt/tmux"] = "tmux next-tmux 3.9\n", ["/opt/zellij"] = "zellij-fork 1.0\nsecond line\n" }
    exec.run = function(argv)
      return { code = 0, stdout = out[argv[1]], stderr = "" }
    end
    fake.reset(nil, { tmux = { enabled = true }, zellij = { enabled = true } })
    check()
    expect.equality(has("info", "tmux: version next-tmux 3.9"), true)
    expect.equality(has("info", "version tmux"), false)
    expect.equality(has("info", "zellij: version zellij-fork 1.0"), true)
    expect.equality(has("info", "second line"), false)
  end)

  it("warns when tmux is older than the floor its backend names, and only then", function()
    muxes(false, false)
    local warned = {}
    for line, expected in pairs({
      ["tmux 3.6b"] = true,
      ["tmux 3.6"] = true,
      ["tmux 2.9a"] = true,
      ["tmux 3.7"] = false,
      ["tmux 3.7a"] = false,
      ["tmux 3.8"] = false,
      ["tmux 3.10"] = false,
      ["tmux 4.0"] = false,
      ["tmux next-3.9"] = false,
      ["tmux master"] = false,
    }) do
      exec.run = function()
        return { code = 0, stdout = line .. "\n", stderr = "" }
      end
      fake.reset(nil, { tmux = { enabled = true } })
      check()
      warned[line] = { has("warn", "tmux: " .. line .. " is older than 3.7"), expected }
    end
    for line, got in pairs(warned) do
      expect.equality({ line, got[1] }, { line, got[2] })
    end
    exec.run = function()
      return { code = 0, stdout = "tmux 3.6\n", stderr = "" }
    end
    check()
    expect.equality(advice("warn", "older than 3.7"), "Upgrade tmux to 3.7 or newer")
  end)

  it("never judges the zellij version", function()
    muxes(false, false)
    exec.run = function()
      return { code = 0, stdout = "zellij 0.1.0\n", stderr = "" }
    end
    fake.reset(nil, { zellij = { enabled = true } })
    check()
    expect.equality(has("warn", "older"), false)
  end)

  it("reports whether tmux.socket is set, without printing its value", function()
    muxes(false, false)
    fake.reset(nil, { tmux = { enabled = true, socket = "/secret/sock" } })
    check()
    expect.equality(has("info", "tmux: socket is configured (tmux.socket)"), true)
    expect.equality(has("info", "/secret/sock"), false)
    fake.reset(nil, { tmux = { enabled = true } })
    check()
    expect.equality(has("info", "tmux: tmux.socket is not configured"), true)
  end)

  it("names all four multiplexers when nvim runs inside none", function()
    fake.reset()
    check()
    expect.equality(has("info", "nvim does not run inside herdr, rex, tmux or zellij: start is unavailable"), true)
  end)

  it("errors for a missing tmux or zellij binary and does not ask it for a version", function()
    for _, name in ipairs({ "tmux", "zellij" }) do
      local b = fake.backend(name)
      b.available = function()
        return false
      end
      package.loaded["sidekick-ultra.backends." .. name] = b
    end
    fake.reset(nil, { tmux = { enabled = true }, zellij = { enabled = true } })
    check()
    expect.equality(has("error", "tmux: binary not found"), true)
    expect.equality(has("error", "zellij: binary not found"), true)
    expect.equality(version_calls, {})
  end)

  it("warns when the version cannot be read", function()
    muxes(false, false)
    local failures = {
      function()
        return nil, require("sidekick-ultra.errors").new("backend_error", "cannot run /opt/tmux: boom")
      end,
      function()
        return { code = 2, stdout = "", stderr = "" }
      end,
    }
    exec.run = function(argv)
      return failures[argv[1] == "/opt/tmux" and 1 or 2]()
    end
    fake.reset(nil, { tmux = { enabled = true }, zellij = { enabled = true } })
    check()
    expect.equality(has("warn", "tmux: cannot read the version: cannot run /opt/tmux: boom"), true)
    expect.equality(has("warn", "zellij: the version command exited with 2"), true)
  end)

  it("lists each configured tool as installed or missing", function()
    fake.reset({ here = { cmd = fake.INSTALLED }, gone = { cmd = { "/nonexistent/sku-gone" } } })
    check()
    expect.equality(has("info", "here: installed"), true)
    expect.equality(has("info", "gone: missing"), true)
  end)

  it("warns that treesitter textobjects are missing", function()
    fake.reset()
    check()
    expect.equality(has("warn", "nvim-treesitter-textobjects"), true)
  end)
end)
