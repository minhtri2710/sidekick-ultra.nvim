local fake = require("tests.helpers.fake")

local expect = MiniTest.expect

describe("health", function()
  local report, orig, loaded

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

  before_each(function()
    orig = {}
    for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
      orig[kind] = vim.health[kind]
      vim.health[kind] = function(msg)
        table.insert(report, { kind = kind, msg = msg })
      end
    end
    loaded = {
      herdr = package.loaded["sidekick-ultra.backends.herdr"],
      rex = package.loaded["sidekick-ultra.backends.rex"],
    }
  end)
  after_each(function()
    for kind, fn in pairs(orig) do
      vim.health[kind] = fn
    end
    package.loaded["sidekick-ultra.backends.herdr"] = loaded.herdr
    package.loaded["sidekick-ultra.backends.rex"] = loaded.rex
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
