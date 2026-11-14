local expect = MiniTest.expect
local location = require("sidekick-ultra.location")
local snapshot = require("sidekick-ultra.context.snapshot")
local sources = require("sidekick-ultra.context.sources")

local builtin = sources.builtin

describe("context.sources", function()
  local dir, other, orig_cwd
  local ns = vim.api.nvim_create_namespace("sku-test")

  ---@param name string
  ---@param lines string[]
  ---@return integer buf
  local function open(name, lines)
    local file = dir .. "/" .. name
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    vim.fn.writefile(lines, file)
    vim.cmd.edit(file)
    return vim.api.nvim_get_current_buf()
  end

  ---@param name string
  ---@param style? string
  local function run(name, style)
    local lines = builtin[name](snapshot.capture())
    if not lines then
      return nil
    end
    return vim.tbl_map(function(line)
      return location.format(type(line) == "string" and { line } or line, style)
    end, lines)
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
    vim.cmd("normal! \27")
    vim.diagnostic.reset(ns)
    vim.fn.setqflist({}, "f")
    vim.cmd("silent! %bwipeout!")
    vim.cmd.cd(orig_cwd)
    vim.fn.delete(dir, "rf")
    vim.fn.delete(other, "rf")
    for _, lang in ipairs({ "lua", "c", "zzz" }) do
      vim.treesitter.query.set(lang, "textobjects", "")
    end
  end)

  describe("locations", function()
    it("writes file, line and position of the cursor", function()
      open("a.lua", { "one", "two" })
      vim.api.nvim_win_set_cursor(0, { 2, 1 })
      expect.equality(run("file"), { "@a.lua" })
      expect.equality(run("line"), { "@a.lua :L2" })
      expect.equality(run("position"), { "@a.lua :L2:C2" })
    end)

    it("applies the location style", function()
      open("my file.lua", { "one", "two" })
      vim.api.nvim_win_set_cursor(0, { 2, 1 })
      expect.equality(run("position", "claude"), { '@"my file.lua"#L2 :C2' })
      expect.equality(run("file", "escaped"), { "@my\\ file.lua" })
    end)

    it("yields nothing outside a file buffer", function()
      vim.cmd.enew()
      vim.bo.buftype = "nofile"
      expect.equality(run("file"), nil)
      expect.equality(run("line"), nil)
      expect.equality(run("position"), nil)
    end)

    it("uses the selection: char range on one line, multi-line range, line kind", function()
      open("a.lua", { "abcdef", "ghijkl" })
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      vim.cmd("normal! vll")
      expect.equality(run("position"), { "@a.lua :L1:C2-C4" })
      expect.equality(run("line"), { "@a.lua :L1" })
      vim.cmd("normal! \27")
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      vim.cmd("normal! vjl")
      expect.equality(run("position"), { "@a.lua :L1:C2-L2:C3" })
      expect.equality(run("line"), { "@a.lua :L1-L2" })
      vim.cmd("normal! \27")
      vim.cmd("normal! ggVj")
      expect.equality(run("position"), { "@a.lua :L1-L2" })
    end)

    it("clamps a selection to the end of line", function()
      open("a.lua", { "abc" })
      vim.cmd("normal! gg0v$")
      expect.equality(run("position"), { "@a.lua :L1:C1-C3" })
    end)

    it("falls back to the absolute path outside the cwd", function()
      vim.fn.writefile({ "x" }, other .. "/b.lua")
      vim.cmd.edit(other .. "/b.lua")
      expect.equality(run("file"), { "@" .. vim.api.nvim_buf_get_name(0) })
    end)
  end)

  describe("buffers", function()
    it("lists listed file buffers in buffer-number order", function()
      open("b.lua", { "x" })
      open("a.lua", { "x" })
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(scratch)
      expect.equality(run("buffers"), { "- @b.lua", "- @a.lua" })
      expect.equality(run("buffers", "claude"), { "- @b.lua", "- @a.lua" })
    end)

    it("yields nothing without file buffers", function()
      expect.equality(run("buffers"), nil)
    end)
  end)

  describe("selection", function()
    it("yields nothing without a selection", function()
      open("a.lua", { "abc" })
      expect.equality(run("selection"), nil)
    end)

    it("takes whole lines, expands tabs and removes the common indent", function()
      open("a.lua", { "top", "\tfoo", "\t\tbar" })
      vim.bo.tabstop = 4
      vim.cmd("normal! 2GVj")
      expect.equality(run("selection"), { "foo", "    bar" })
    end)

    it("ignores blank lines when finding the common indent", function()
      open("a.lua", { "    a", "", "      b" })
      vim.cmd("normal! ggVG")
      expect.equality(run("selection"), { "a", "", "  b" })
    end)

    it("pads the first line of a char selection back to its column", function()
      open("a.lua", { "    local x = 1", "    return x" })
      vim.api.nvim_win_set_cursor(0, { 1, 10 })
      vim.cmd("normal! v4l")
      expect.equality(run("selection"), { "x = 1" })
      vim.cmd("normal! \27")
      vim.api.nvim_win_set_cursor(0, { 1, 10 })
      vim.cmd("normal! vjh")
      expect.equality(run("selection"), { "      x = 1", "return" })
    end)

    it("includes the whole last multibyte character of a char selection", function()
      open("a.lua", { "xéy" })
      vim.cmd("normal! 0vl")
      expect.equality(run("selection"), { "xé" })
    end)

    it("keeps combining marks and joined emoji with their character", function()
      local nfd = "cafe" .. vim.fn.nr2char(0x301) .. " x"
      local zwj = vim.fn.nr2char(0x1F468) .. vim.fn.nr2char(0x200D) .. vim.fn.nr2char(0x1F469) .. " x"
      open("a.lua", { nfd, zwj })
      vim.cmd("normal! gg0v$h")
      expect.equality(run("selection"), { nfd })
      vim.cmd("normal! \27G0v$h")
      expect.equality(run("selection"), { zwj })
      vim.cmd("normal! \27G$\22k")
      -- the joined emoji line puts its x on column 4, which is where the block starts on the NFD line too
      expect.equality(run("selection"), { "e" .. vim.fn.nr2char(0x301) .. " x", "x" })
    end)

    it("cuts the same display columns on every line of a block", function()
      open("a.lua", { "abcdef", "ghijkl", "mnopqr" })
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      vim.cmd("normal! \22jjl")
      expect.equality(run("selection"), { "bc", "hi", "no" })
    end)

    it("counts display columns for wide characters in a block", function()
      open("a.lua", { "日本語", "abcdef" })
      vim.cmd("normal! gg0\22j")
      -- the first mark covers display columns 1-2 of the wide character
      expect.equality(run("selection"), { "日", "ab" })
    end)

    it("takes each line of a block to its end after $", function()
      open("a.lua", { "ab", "abcdefgh", "abc" })
      vim.cmd("normal! gg0\22jj$")
      expect.equality(run("selection"), { "ab", "abcdefgh", "abc" })
    end)

    describe("with selection=exclusive", function()
      before_each(function()
        vim.o.selection = "exclusive"
      end)

      after_each(function()
        vim.o.selection = "inclusive"
      end)

      it("leaves out the character under the end of a char selection", function()
        open("a.lua", { "hello world", "ab", "cd" })
        vim.cmd("normal! 0vw")
        expect.equality(run("selection"), { "hello " })
        vim.cmd("normal! \27gg0v")
        expect.equality(run("selection"), { "h" })
        vim.cmd("normal! \0272Gvj")
        expect.equality(run("selection"), { "ab", "" })
      end)

      it("leaves out the end column of a block only when the end mark holds the right edge", function()
        open("a.lua", { "abcdef", "ghijkl", "mnopqr" })
        vim.cmd("normal! gg0\22jjl")
        expect.equality(run("selection"), { "a", "g", "m" })
        vim.cmd("normal! \27gg0ll\22jjh")
        expect.equality(run("selection"), { "bc", "hi", "no" })
        -- the end mark's tab starts inside the columns the start mark covers, so no column may be dropped
        vim.cmd("normal! \27")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdefghij", "\tx" })
        vim.cmd("normal! gg0\22j")
        expect.equality(run("selection"), { "abcdefgh", "        " })
      end)
    end)

    it("writes a NUL byte as ^@, two columns, in a char, block and line selection", function()
      open("a.lua", { "x" })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a\0b c", "x\0y z" })
      vim.cmd("normal! gg0v$h")
      expect.equality(run("selection"), { "a^@b c" })
      expect.equality(run("position"), { "@a.lua :L1:C1-C5" })
      vim.cmd("normal! \27gg0\22jl")
      expect.equality(run("selection"), { "a^@", "x^@" })
      vim.cmd("normal! \27gg0\22j$")
      expect.equality(run("selection"), { "a^@b c", "x^@y z" })
      vim.cmd("normal! \27ggVj")
      expect.equality(run("selection"), { "a^@b c", "x^@y z" })
    end)

    it("writes CR and ESC in caret notation, two columns each, in a char and block selection", function()
      open("a.lua", { "x" })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a\rb c", "x\27y z" })
      vim.cmd("normal! gg0v$h")
      expect.equality(run("selection"), { "a^Mb c" })
      vim.cmd("normal! \27gg0\22jl")
      expect.equality(run("selection"), { "a^M", "x^[" })
      vim.cmd("normal! \27gg0\22j$")
      expect.equality(run("selection"), { "a^Mb c", "x^[y z" })
    end)

    it("handles blank lines in a char selection", function()
      open("a.lua", { "", "abc" })
      vim.cmd("normal! ggvj")
      expect.equality(run("selection"), { "", "a" })
    end)
  end)

  describe("diagnostics", function()
    local function set(buf, list)
      vim.diagnostic.set(ns, buf, list)
    end

    it("formats severity, message, source, code and the position range", function()
      local buf = open("a.lua", { "one", "two" })
      set(buf, {
        { lnum = 1, col = 1, end_lnum = 1, end_col = 3, severity = vim.diagnostic.severity.WARN, message = "w" },
        {
          lnum = 0,
          col = 4,
          end_lnum = 0,
          end_col = 7,
          severity = vim.diagnostic.severity.ERROR,
          message = "bad",
          source = "lua_ls",
          code = 12,
        },
      })
      expect.equality(run("diagnostics"), {
        "[ERROR] bad lua_ls 12 @a.lua :L1:C5-C7",
        "[WARN] w @a.lua :L2:C2-C3",
      })
      expect.equality(run("diagnostics", "claude")[1], "[ERROR] bad lua_ls 12 @a.lua#L1 :C5-C7")
    end)

    it("writes a point for a one-character diagnostic and a multi-line range", function()
      local buf = open("a.lua", { "one", "two" })
      set(buf, {
        { lnum = 0, col = 1, end_lnum = 0, end_col = 2, severity = 3, message = "i" },
        { lnum = 0, col = 2, end_lnum = 1, end_col = 2, severity = 4, message = "h" },
      })
      expect.equality(run("diagnostics"), {
        "[INFO] i @a.lua :L1:C2",
        "[HINT] h @a.lua :L1:C3-L2:C2",
      })
    end)

    it("sorts by line then column", function()
      local buf = open("a.lua", { "one", "two", "three" })
      set(buf, {
        { lnum = 2, col = 0, severity = 1, message = "c" },
        { lnum = 0, col = 2, severity = 1, message = "b" },
        { lnum = 0, col = 0, severity = 1, message = "a" },
      })
      local out = run("diagnostics")
      expect.equality(
        vim.tbl_map(function(l)
          return l:match("^%[ERROR%] (%a)")
        end, out),
        { "a", "b", "c" }
      )
    end)

    it("continues a multi-line message on the following lines", function()
      local buf = open("a.lua", { "one" })
      set(buf, { { lnum = 0, col = 0, severity = 1, message = "first\nsecond\nthird" } })
      expect.equality(run("diagnostics"), { "[ERROR] first @a.lua :L1:C1", "second", "third" })
    end)

    it("keeps only diagnostics that start inside the selection", function()
      local buf = open("a.lua", { "one", "two", "three" })
      set(buf, {
        { lnum = 0, col = 0, severity = 1, message = "a" },
        { lnum = 1, col = 0, severity = 1, message = "b" },
        { lnum = 2, col = 0, severity = 1, message = "c" },
      })
      vim.cmd("normal! 2GV")
      expect.equality(run("diagnostics"), { "[ERROR] b @a.lua :L2:C1" })
    end)

    it("yields nothing without diagnostics", function()
      open("a.lua", { "one" })
      expect.equality(run("diagnostics"), nil)
      expect.equality(run("diagnostics_all"), nil)
    end)

    it("diagnostics_all covers other buffers and filters only the current one", function()
      local a = open("a.lua", { "one", "two" })
      local b = open("b.lua", { "x", "y" })
      set(a, { { lnum = 0, col = 0, severity = 1, message = "in a line 1" } })
      set(
        b,
        { { lnum = 1, col = 0, severity = 2, message = "in b" }, { lnum = 0, col = 0, severity = 2, message = "b0" } }
      )
      vim.api.nvim_set_current_buf(a)
      expect.equality(run("diagnostics"), { "[ERROR] in a line 1 @a.lua :L1:C1" })
      expect.equality(run("diagnostics_all"), {
        "[ERROR] in a line 1 @a.lua :L1:C1",
        "[WARN] b0 @b.lua :L1:C1",
        "[WARN] in b @b.lua :L2:C1",
      })
      vim.cmd("normal! 2GV")
      expect.equality(run("diagnostics_all"), {
        "[WARN] b0 @b.lua :L1:C1",
        "[WARN] in b @b.lua :L2:C1",
      })
    end)
  end)

  describe("quickfix", function()
    it("yields nothing for an empty list", function()
      expect.equality(run("quickfix"), nil)
    end)

    it("writes the title and one line per item", function()
      open("a.lua", { "one", "two" })
      local file = dir .. "/a.lua"
      vim.fn.setqflist({}, " ", {
        title = "Grep",
        items = {
          { filename = file, lnum = 2, col = 3, text = "oops   ", type = "e" },
          { filename = file, lnum = 1, col = 0, end_lnum = 2, end_col = 3, text = "range" },
          { filename = file, lnum = 1, col = 2, end_lnum = 1, end_col = 4, text = "same line" },
          { filename = file, lnum = 2, col = 1, end_lnum = 2, end_col = 1, text = "empty end" },
          { filename = file, text = "whole file" },
          { text = "nameless" },
        },
      })
      expect.equality(run("quickfix"), {
        "Quickfix: Grep",
        "- @a.lua :L2:C3 [E] oops",
        "- @a.lua :L1:C1-L2:C2 range",
        "- @a.lua :L1:C2-C3 same line",
        "- @a.lua :L2:C1 empty end",
        "- @a.lua whole file",
        "- @[No Name] nameless",
      })
      expect.equality(run("quickfix", "claude")[2], "- @a.lua#L2 :C3 [E] oops")
    end)

    it("omits an empty or command title and indents continuation lines", function()
      open("a.lua", { "one" })
      vim.fn.setqflist(
        {},
        " ",
        { title = ":vimgrep x", items = { { filename = dir .. "/a.lua", lnum = 1, text = "a\nb" } } }
      )
      expect.equality(run("quickfix"), { "- @a.lua :L1:C1 a", "  b" })
    end)
  end)

  describe("function and class", function()
    it("yield nothing without a textobjects query", function()
      open("a.lua", { "local function f()", "  return 1", "end" })
      vim.bo.filetype = "lua"
      expect.equality(run("function"), nil)
      expect.equality(run("class"), nil)
    end)

    it("yield nothing without a parser", function()
      open("a.zzz", { "x" })
      vim.bo.filetype = "zzz"
      expect.equality(run("function"), nil)
    end)

    it("name the enclosing node when a textobjects query exists", function()
      vim.treesitter.query.set("lua", "textobjects", "(function_declaration) @function.outer")
      open("a.lua", { "local x = 1", "local function f()", "  return 1", "end" })
      vim.bo.filetype = "lua"
      vim.api.nvim_win_set_cursor(0, { 3, 4 })
      expect.equality(run("function"), { "function f @a.lua :L2:C1" })
      expect.equality(run("function", "claude"), { "function f @a.lua#L2 :C1" })
      expect.equality(run("class"), nil)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      expect.equality(run("function"), nil)
    end)

    it("picks the innermost node when functions nest", function()
      vim.treesitter.query.set("lua", "textobjects", "(function_declaration) @function.outer")
      open("a.lua", { "function outer()", "  local function inner()", "    return 1", "  end", "end" })
      vim.bo.filetype = "lua"
      vim.api.nvim_win_set_cursor(0, { 3, 4 })
      expect.equality(run("function"), { "function inner @a.lua :L2:C3" })
    end)

    describe("the name", function()
      ---The text `function` yields at `cursor` of `lines`, with `query` as the buffer language's textobjects.
      local function named(file, lang, query, lines, cursor, word)
        vim.treesitter.query.set(lang, "textobjects", query)
        open(file, lines)
        vim.bo.filetype = lang
        vim.api.nvim_win_set_cursor(0, cursor)
        return run(word or "function")
      end

      it("is the whole name field, however it is written", function()
        local got = named(
          "a.lua",
          "lua",
          "(function_declaration) @function.outer",
          { "function M.foo() end" },
          { 1, 12 }
        )
        expect.equality(got, { "function M.foo @a.lua :L1:C1" })
      end)

      it("is the field child when the node has no name field", function()
        local got = named("a.lua", "lua", "(dot_index_expression) @function.outer", { "local x = a.b" }, { 1, 12 })
        expect.equality(got, { "function b @a.lua :L1:C11" })
      end)

      it("is the first identifier child when the node has no name, identifier or field", function()
        local got = named(
          "a.c",
          "c",
          "(function_declarator) @function.outer",
          { "int main(void) {", "  return 0;", "}" },
          { 1, 5 }
        )
        expect.equality(got, { "function main @a.c :L1:C5" })
      end)

      it("is left out, with the word and the location kept, when the node has none", function()
        local lines = { "local f = function() return 1 end" }
        local query = "(function_definition) @%s.outer"
        expect.equality(
          named("a.lua", "lua", query:format("function"), lines, { 1, 12 }),
          { "function @a.lua :L1:C11" }
        )
        expect.equality(
          named("b.lua", "lua", query:format("class"), lines, { 1, 12 }, "class"),
          { "class @b.lua :L1:C11" }
        )
      end)
    end)
  end)
end)
