local expect = MiniTest.expect
local snapshot = require("sidekick-ultra.context.snapshot")

describe("context.snapshot", function()
  local dir, orig_cwd

  ---@param name string
  ---@param lines string[]
  local function write(name, lines)
    local file = dir .. "/" .. name
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    vim.fn.writefile(lines, file)
    return file
  end

  before_each(function()
    orig_cwd = vim.fn.getcwd()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.cmd.cd(dir)
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    vim.cmd.cd(orig_cwd)
    vim.fn.delete(dir, "rf")
  end)

  describe("capture", function()
    it("records window, buffer, cwd and a 1-based cursor", function()
      vim.cmd.edit(write("a.lua", { "one", "two", "three" }))
      vim.api.nvim_win_set_cursor(0, { 2, 2 })
      local snap = snapshot.capture()
      expect.equality(snap.win, vim.api.nvim_get_current_win())
      expect.equality(snap.buf, vim.api.nvim_get_current_buf())
      expect.equality(snap.cwd, vim.fn.getcwd())
      expect.equality(snap.cursor, { 2, 3 })
      expect.equality(snap.selection, nil)
    end)

    it("reads a linewise selection and keeps visual mode", function()
      vim.cmd.edit(write("a.lua", { "one", "two", "three" }))
      vim.cmd("normal! jVj")
      local snap = snapshot.capture()
      expect.equality(snap.selection, { kind = "line", from = { 2, 1 }, to = { 3, 1 } })
      expect.equality(vim.fn.mode(), "V")
    end)

    it("orders the marks when the cursor is above the anchor", function()
      vim.cmd.edit(write("a.lua", { "abc", "def", "ghi" }))
      vim.api.nvim_win_set_cursor(0, { 3, 2 })
      vim.cmd("normal! vkh")
      local sel = snapshot.capture().selection
      expect.equality(sel.kind, "char")
      expect.equality(sel.from, { 2, 2 })
      expect.equality(sel.to, { 3, 3 })
    end)

    it("reads a blockwise selection", function()
      vim.cmd.edit(write("a.lua", { "abc", "def", "ghi" }))
      vim.cmd("normal! \22jl")
      local sel = snapshot.capture().selection
      expect.equality(sel.kind, "block")
      expect.equality(sel.from, { 1, 1 })
      expect.equality(sel.to, { 2, 2 })
    end)

    it("has no selection once visual mode is left", function()
      vim.cmd.edit(write("a.lua", { "abc" }))
      vim.cmd("normal! v\27")
      expect.equality(snapshot.capture().selection, nil)
    end)
  end)

  describe("is_file", function()
    it("accepts a listed buffer of a readable file", function()
      vim.cmd.edit(write("a.lua", { "x" }))
      expect.equality(snapshot.is_file(vim.api.nvim_get_current_buf()), true)
    end)

    it("rejects an unnamed buffer, a scratch buffer and a missing file", function()
      expect.equality(snapshot.is_file(vim.api.nvim_create_buf(true, false)), false)
      expect.equality(snapshot.is_file(vim.api.nvim_create_buf(false, true)), false)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, dir .. "/missing.lua")
      expect.equality(snapshot.is_file(buf), false)
    end)

    it("rejects an unlisted buffer and a non-file buftype", function()
      vim.cmd.edit(write("a.lua", { "x" }))
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype = "nofile"
      expect.equality(snapshot.is_file(buf), false)
      vim.bo[buf].buftype = ""
      vim.bo[buf].buflisted = false
      expect.equality(snapshot.is_file(buf), false)
    end)

    it("accepts a listed help buffer", function()
      vim.cmd.edit(write("a.txt", { "x" }))
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype = "help"
      expect.equality(snapshot.is_file(buf), true)
    end)

    it("rejects an invalid buffer", function()
      expect.equality(snapshot.is_file(99999), false)
    end)
  end)

  describe("path", function()
    it("is relative to the cwd when under it", function()
      vim.cmd.edit(write("sub/a.lua", { "x" }))
      expect.equality(snapshot.path(vim.api.nvim_get_current_buf(), vim.fn.getcwd()), "sub/a.lua")
    end)

    it("resolves symlinks when the plain prefix does not match", function()
      local real = write("sub/a.lua", { "x" })
      local link = dir .. "-link"
      vim.uv.fs_symlink(dir, link)
      vim.cmd.edit(link .. "/sub/a.lua")
      expect.equality(vim.fn.filereadable(real), 1)
      expect.equality(snapshot.path(vim.api.nvim_get_current_buf(), vim.fn.getcwd()), "sub/a.lua")
      vim.cmd("silent! %bwipeout!")
      vim.uv.fs_unlink(link)
    end)

    it("is absolute outside the cwd", function()
      local other = vim.fn.tempname()
      vim.fn.mkdir(other, "p")
      vim.fn.writefile({ "x" }, other .. "/b.lua")
      vim.cmd.edit(other .. "/b.lua")
      local buf = vim.api.nvim_get_current_buf()
      expect.equality(snapshot.path(buf, vim.fn.getcwd()), vim.api.nvim_buf_get_name(buf))
      vim.cmd("silent! %bwipeout!")
      vim.fn.delete(other, "rf")
    end)

    it("is [No Name] for an unnamed buffer", function()
      expect.equality(snapshot.path(vim.api.nvim_create_buf(true, false), vim.fn.getcwd()), "[No Name]")
    end)
  end)
end)
