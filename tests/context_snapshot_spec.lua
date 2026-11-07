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
    it("records buffer, cwd and a 1-based cursor", function()
      vim.cmd.edit(write("a.lua", { "one", "two", "three" }))
      vim.api.nvim_win_set_cursor(0, { 2, 2 })
      local snap = snapshot.capture()
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
end)
