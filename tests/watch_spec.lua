local fake = require("tests.helpers.fake")
local registry = require("sidekick-ultra.registry")
local watch = require("sidekick-ultra.watch")

local expect = MiniTest.expect

local flush = fake.flush

---The first line of the buffer that shows `path`.
---@param path string
---@return string
local function first_line(path)
  return vim.api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, 1, false)[1]
end

---Write `tag .. n` to the file, and again every second until `cond` holds. A change made right after a watcher starts
---can be missed by the operating system's file events, so one write is not enough to wait on. The pause is longer than
---the watcher's debounce, so a rewrite never postpones the reload it is waiting for.
---@param path string
---@param tag string
---@param cond fun(): boolean
local function write_until(path, tag, cond)
  local deadline, n = vim.uv.now() + 5000, 0
  while vim.uv.now() < deadline do
    n = n + 1
    vim.fn.writefile({ tag .. n, "more" }, path)
    if vim.wait(1000, cond, 10) then
      return true
    end
  end
  return false
end

---Whether the buffer that shows `path` reloads after the file is edited under it.
---@param path string
---@param tag string
---@return boolean
local function reloads(path, tag)
  return write_until(path, tag, function()
    return vim.startswith(first_line(path), tag)
  end)
end

---Edit the file under its buffer and check the buffer keeps its text. An observer of its own proves the file events
---do arrive; only then does "no reload" mean anything.
---@param path string
local function expect_no_reload(path)
  local before = first_line(path)
  local seen = false
  local observer = assert(vim.uv.new_fs_event())
  observer:start(vim.fs.dirname(path), {}, function()
    seen = true
  end)
  local delivered = write_until(path, "unseen ", function()
    return seen
  end)
  observer:close()
  expect.equality(delivered, true)
  -- A reload would follow the event by one debounce period (100 ms); 300 ms is three of them.
  vim.wait(300, function()
    return false
  end)
  expect.equality(first_line(path), before)
end

describe("watch", function()
  local dir_a, dir_b, file_a, file_b

  ---@param path string
  local function open(path)
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
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

  it("reloads a buffer when the agent edits its file, from the first attach to the last detach", function()
    open(file_a)
    expect_no_reload(file_a)
    registry.attach(fake.session("herdr", "claude", 1))
    registry.attach(fake.session("herdr", "claude", 2))
    flush()
    expect.equality(reloads(file_a, "first "), true)
    registry.detach("herdr:claude1")
    flush()
    expect.equality(reloads(file_a, "second "), true)
    registry.detach("herdr:claude2")
    flush()
    expect_no_reload(file_a)
  end)

  it("never reloads when the watch option is false", function()
    fake.reset({ claude = { cmd = fake.INSTALLED } }, { watch = false })
    open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    expect_no_reload(file_a)
  end)

  it("follows the option it was set up with, not the stored configuration", function()
    watch.setup(false)
    open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    expect_no_reload(file_a)
    watch.setup(true)
    registry.attach(fake.session("herdr", "claude", 2))
    flush()
    expect.equality(reloads(file_a, "enabled "), true)
  end)

  it("reloads the buffers of files opened after the watcher started", function()
    open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    vim.cmd("split")
    open(file_b)
    expect.equality(reloads(file_b, "later "), true)
    expect.equality(reloads(file_a, "earlier "), true)
  end)

  it("leaves no buffer autocommands behind after the last detach", function()
    local function buffer_autocmds()
      return #vim.api.nvim_get_autocmds({ event = { "BufAdd", "BufDelete", "BufWipeout", "BufReadPost" } })
    end
    local before = buffer_autocmds()
    open(file_a)
    registry.attach(fake.session("herdr", "claude"))
    flush()
    expect.equality(buffer_autocmds() > before, true)
    registry.detach("herdr:claude1")
    flush()
    expect.equality(buffer_autocmds(), before)
  end)
end)
