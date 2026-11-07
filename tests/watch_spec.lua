local fake = require("tests.helpers.fake")
local registry = require("sidekick-ultra.registry")
local watch = require("sidekick-ultra.watch")

local expect = MiniTest.expect

local flush = fake.flush

local function wait_for(cond)
  return vim.wait(3000, cond, 20)
end

---Write the file, and again every second until `cond` holds. A change made right after a watcher starts can be
---missed by the operating system's file events, so one write is not enough to wait on. The pause is longer than the
---watcher's debounce, so a rewrite never postpones the reload it is waiting for.
---@param path string
---@param cond fun(): boolean
local function write_until(path, cond)
  local deadline, n = vim.uv.now() + 5000, 0
  while vim.uv.now() < deadline do
    n = n + 1
    vim.fn.writefile({ "changed " .. n, "more" }, path)
    if vim.wait(1000, cond, 10) then
      return true
    end
  end
  return false
end

describe("watch", function()
  local dir_a, dir_b, file_a, file_b

  ---@param path string
  local function open(path)
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    return vim.fs.dirname(vim.api.nvim_buf_get_name(0))
  end

  before_each(function()
    fake.reset({ claude = { cmd = fake.INSTALLED } })
    local root = vim.fn.resolve(vim.fn.tempname())
    dir_a, dir_b = root .. "/a", root .. "/b"
    vim.fn.mkdir(dir_a, "p")
    vim.fn.mkdir(dir_b, "p")
    file_a, file_b = dir_a .. "/one.txt", dir_b .. "/two.txt"
    vim.fn.writefile({ "one" }, file_a)
    vim.fn.writefile({ "two" }, file_b)
  end)
  after_each(function()
    registry.reset()
    watch.stop()
    vim.cmd("silent! %bwipeout!")
  end)

  it("is off until a session is attached, on after the first attach, off after the last detach", function()
    local real_a = open(file_a)
    expect.equality({ watch.active(), watch.dirs() }, { false, {} })
    registry.attach(fake.session("herdr", "claude", 1))
    registry.attach(fake.session("herdr", "claude", 2))
    flush()
    expect.equality({ watch.active(), watch.dirs() }, { true, { real_a } })
    registry.detach("herdr:claude1")
    flush()
    expect.equality(watch.active(), true)
    registry.detach("herdr:claude2")
    flush()
    expect.equality({ watch.active(), watch.dirs() }, { false, {} })
  end)

  it("never starts when the watch option is false", function()
    fake.reset({ claude = { cmd = fake.INSTALLED } }, { watch = false })
    open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    expect.equality(watch.active(), false)
  end)

  it("follows the option it was set up with, not the stored configuration", function()
    watch.setup(false)
    open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    expect.equality(watch.active(), false)
    watch.setup(true)
    registry.attach(fake.session("herdr", "claude", 2))
    flush()
    expect.equality(watch.active(), true)
  end)

  it("watches the directory of every listed file buffer and recomputes after buffer events", function()
    local real_a = open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    local real_b = open(file_b)
    expect.equality(
      wait_for(function()
        return #watch.dirs() == 2
      end),
      true
    )
    expect.equality(watch.dirs(), vim.fn.sort({ real_a, real_b }))
    vim.cmd("silent bwipeout! " .. vim.fn.bufnr(file_b))
    expect.equality(
      wait_for(function()
        return #watch.dirs() == 1
      end),
      true
    )
    expect.equality(watch.dirs(), { real_a })
  end)

  it("ignores scratch buffers and buffers whose file does not exist", function()
    open(dir_a .. "/missing.txt")
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    registry.attach(fake.session("herdr", "claude"))
    flush()
    expect.equality({ watch.active(), watch.dirs() }, { true, {} })
  end)

  it("reloads a buffer when the agent edits its file", function()
    open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    expect.equality(
      write_until(file_a, function()
        return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] ~= "one"
      end),
      true
    )
    expect.equality(vim.startswith(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "changed "), true)
  end)

  it("does not reload after the last detach", function()
    open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    registry.detach("herdr:claude1")
    flush()
    -- An observer of its own proves the file events do arrive; only then does "no reload" mean anything.
    local seen = false
    local observer = assert(vim.uv.new_fs_event())
    observer:start(dir_a, {}, function()
      seen = true
    end)
    local delivered = write_until(file_a, function()
      return seen
    end)
    observer:close()
    expect.equality(delivered, true)
    -- A reload would follow the event by one debounce period (100 ms); 300 ms is three of them.
    vim.wait(300, function()
      return false
    end)
    expect.equality(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "one")
  end)

  it("removes its autocommands when stopped", function()
    open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    expect.equality(#vim.api.nvim_get_autocmds({ group = "sidekick-ultra-watch" }) > 0, true)
    registry.detach("herdr:claude1")
    flush()
    expect.equality(pcall(vim.api.nvim_get_autocmds, { group = "sidekick-ultra-watch" }), false)
  end)
end)
