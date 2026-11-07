local expect = MiniTest.expect
local location = require("sidekick-ultra.location")

describe("location", function()
  local dir, other, orig_cwd

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
    other = vim.fn.tempname()
    vim.fn.mkdir(other, "p")
    vim.cmd.cd(dir)
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    vim.cmd.cd(orig_cwd)
    vim.fn.delete(dir, "rf")
    vim.fn.delete(other, "rf")
  end)

  describe("text", function()
    local function loc(fields)
      return vim.tbl_extend("force", { path = "a.lua" }, fields)
    end

    it("plain", function()
      expect.equality(location.text(loc({ kind = "file" })), "@a.lua")
      expect.equality(location.text(loc({ kind = "line", r1 = 3 }), "plain"), "@a.lua :L3")
      expect.equality(location.text(loc({ kind = "line", r1 = 3, r2 = 3 })), "@a.lua :L3")
      expect.equality(location.text(loc({ kind = "line", r1 = 3, r2 = 5 })), "@a.lua :L3-L5")
      expect.equality(location.text(loc({ kind = "position", r1 = 3, c1 = 4 })), "@a.lua :L3:C4")
      expect.equality(location.text(loc({ kind = "position", r1 = 3, c1 = 4, r2 = 3, c2 = 4 })), "@a.lua :L3:C4")
      expect.equality(location.text(loc({ kind = "position", r1 = 3, c1 = 4, r2 = 3, c2 = 9 })), "@a.lua :L3:C4-C9")
      expect.equality(location.text(loc({ kind = "position", r1 = 3, c1 = 4, r2 = 5, c2 = 2 })), "@a.lua :L3:C4-L5:C2")
    end)

    it("claude", function()
      expect.equality(location.text(loc({ kind = "file" }), "claude"), "@a.lua")
      expect.equality(location.text(loc({ kind = "line", r1 = 10, r2 = 20 }), "claude"), "@a.lua#L10-20")
      expect.equality(location.text(loc({ kind = "line", r1 = 10 }), "claude"), "@a.lua#L10")
      expect.equality(location.text(loc({ kind = "position", r1 = 10, c1 = 5 }), "claude"), "@a.lua#L10 :C5")
      expect.equality(
        location.text(loc({ kind = "position", r1 = 10, c1 = 5, r2 = 10, c2 = 8 }), "claude"),
        "@a.lua#L10 :C5-C8"
      )
      expect.equality(
        location.text(loc({ kind = "position", r1 = 1, c1 = 2, r2 = 3, c2 = 4 }), "claude"),
        "@a.lua#L1-3"
      )
    end)

    it("claude quotes a path with unusual characters", function()
      expect.equality(location.text(loc({ path = "my file.lua", kind = "file" }), "claude"), '@"my file.lua"')
      expect.equality(
        location.text(loc({ path = "a(1).lua", kind = "line", r1 = 2, r2 = 4 }), "claude"),
        '@"a(1).lua"#L2-4'
      )
      expect.equality(location.text(loc({ path = "dir/sub-1/a_b.lua", kind = "file" }), "claude"), "@dir/sub-1/a_b.lua")
    end)

    it("escaped backslash-escapes every unusual path character", function()
      expect.equality(
        location.text(loc({ path = "my file(1).lua", kind = "file" }), "escaped"),
        "@my\\ file\\(1\\).lua"
      )
      expect.equality(location.text(loc({ path = "[No Name]", kind = "file" }), "escaped"), "@\\[No\\ Name\\]")
      expect.equality(
        location.text(loc({ path = "a b.lua", kind = "line", r1 = 3, r2 = 5 }), "escaped"),
        "@a\\ b.lua :L3-L5"
      )
      expect.equality(location.text(loc({ kind = "position", r1 = 3, c1 = 4 }), "escaped"), "@a.lua :L3:C4")
    end)

    it("plain leaves the path alone", function()
      expect.equality(location.text(loc({ path = "my file.lua", kind = "file" }), "plain"), "@my file.lua")
    end)
  end)

  describe("is_file", function()
    it("accepts a listed buffer of a readable file", function()
      vim.cmd.edit(write("a.lua", { "x" }))
      expect.equality(location.is_file(vim.api.nvim_get_current_buf()), true)
    end)

    it("rejects an unnamed buffer, a scratch buffer and a missing file", function()
      expect.equality(location.is_file(vim.api.nvim_create_buf(true, false)), false)
      expect.equality(location.is_file(vim.api.nvim_create_buf(false, true)), false)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, dir .. "/missing.lua")
      expect.equality(location.is_file(buf), false)
    end)

    it("rejects an unlisted buffer and a non-file buftype", function()
      vim.cmd.edit(write("a.lua", { "x" }))
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype = "nofile"
      expect.equality(location.is_file(buf), false)
      vim.bo[buf].buftype = ""
      vim.bo[buf].buflisted = false
      expect.equality(location.is_file(buf), false)
    end)

    it("accepts a listed help buffer", function()
      vim.cmd.edit(write("a.txt", { "x" }))
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype = "help"
      expect.equality(location.is_file(buf), true)
    end)

    it("rejects an invalid buffer", function()
      expect.equality(location.is_file(99999), false)
    end)
  end)

  describe("path", function()
    it("is relative to the cwd when under it", function()
      vim.cmd.edit(write("sub/a.lua", { "x" }))
      expect.equality(location.path(vim.api.nvim_get_current_buf(), vim.fn.getcwd()), "sub/a.lua")
    end)

    it("resolves symlinks when the plain prefix does not match", function()
      local real = write("sub/a.lua", { "x" })
      local link = dir .. "-link"
      vim.uv.fs_symlink(dir, link)
      vim.cmd.edit(link .. "/sub/a.lua")
      expect.equality(vim.fn.filereadable(real), 1)
      expect.equality(location.path(vim.api.nvim_get_current_buf(), vim.fn.getcwd()), "sub/a.lua")
      vim.cmd("silent! %bwipeout!")
      vim.uv.fs_unlink(link)
    end)

    it("is absolute outside the cwd", function()
      vim.fn.writefile({ "x" }, other .. "/b.lua")
      vim.cmd.edit(other .. "/b.lua")
      local buf = vim.api.nvim_get_current_buf()
      expect.equality(location.path(buf, vim.fn.getcwd()), vim.api.nvim_buf_get_name(buf))
    end)

    it("is [No Name] for an unnamed buffer", function()
      expect.equality(location.path(vim.api.nvim_create_buf(true, false), vim.fn.getcwd()), "[No Name]")
    end)
  end)

  describe("format", function()
    it("writes strings as they are and location records in the style", function()
      local segments = { "see ", { path = "a b.lua", kind = "line", r1 = 2 }, "!" }
      expect.equality(location.format(segments), "see @a b.lua :L2!")
      expect.equality(location.format(segments, "escaped"), "see @a\\ b.lua :L2!")
      expect.equality(location.format({}), "")
    end)
  end)

  describe("is_location", function()
    it("accepts each kind with the rows and columns it needs", function()
      expect.equality(location.is_location({ path = "a", kind = "file" }), true)
      expect.equality(location.is_location({ path = "a", kind = "line", r1 = 1 }), true)
      expect.equality(location.is_location({ path = "a", kind = "line", r1 = 1, r2 = 3 }), true)
      expect.equality(location.is_location({ path = "a", kind = "position", r1 = 1, c1 = 2 }), true)
    end)

    it("rejects a missing or unknown kind, a non-string path, a missing row or column and non-integers", function()
      expect.equality(location.is_location({ path = "a" }), false)
      expect.equality(location.is_location({ path = "a", kind = "word" }), false)
      expect.equality(location.is_location({ path = 1, kind = "file" }), false)
      expect.equality(location.is_location({ path = "a", kind = "line" }), false)
      expect.equality(location.is_location({ path = "a", kind = "position", r1 = 1 }), false)
      expect.equality(location.is_location({ path = "a", kind = "line", r1 = 1.5 }), false)
      expect.equality(location.is_location({ path = "a", kind = "line", r1 = 1, r2 = "2" }), false)
    end)
  end)

  describe("file and line", function()
    it("builds a file record from the path alone", function()
      expect.equality(location.file("a"), { path = "a", kind = "file" })
    end)

    it("ends a line record on its first row when no last row is given", function()
      expect.equality(location.line("a", 3), { path = "a", kind = "line", r1 = 3, r2 = 3 })
      expect.equality(location.line("a", 3, 5), { path = "a", kind = "line", r1 = 3, r2 = 5 })
    end)

    it("builds records that is_location accepts", function()
      expect.equality(location.is_location(location.file("a")), true)
      expect.equality(location.is_location(location.line("a", 3)), true)
    end)
  end)

  describe("position", function()
    it("ends where it starts when no end is given", function()
      expect.equality(location.position("a", 3, 4), { path = "a", kind = "position", r1 = 3, c1 = 4, r2 = 3, c2 = 4 })
    end)

    it("never ends before its start column on one row", function()
      expect.equality(location.position("a", 3, 4, 3, 2).c2, 4)
      expect.equality(location.position("a", 3, 4, 3, 9).c2, 9)
    end)

    it("keeps the end column of a later row, at least column 1", function()
      expect.equality(location.position("a", 3, 4, 5, 2).c2, 2)
      expect.equality(location.position("a", 3, 4, 5, 0).c2, 1)
      expect.equality(location.position("a", 3, 4, 5).c2, 4)
    end)
  end)
end)
