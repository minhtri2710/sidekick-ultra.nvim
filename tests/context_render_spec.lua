local expect = MiniTest.expect
local render = require("sidekick-ultra.context.render")
local snapshot = require("sidekick-ultra.context.snapshot")

describe("context.render", function()
  local dir, orig_cwd

  local function open(name, lines)
    local file = dir .. "/" .. name
    vim.fn.writefile(lines, file)
    vim.cmd.edit(file)
  end

  local function scratch(lines)
    vim.cmd.enew()
    vim.bo.buftype = "nofile"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end

  ---@param opts table
  ---@param style? string
  local function run(opts, style)
    return render.render(opts, snapshot.capture(), style)
  end

  before_each(function()
    orig_cwd = vim.fn.getcwd()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.cmd.cd(dir)
    render.setup()
  end)

  after_each(function()
    vim.cmd("normal! \27")
    vim.cmd("silent! %bwipeout!")
    vim.cmd.cd(orig_cwd)
    vim.fn.delete(dir, "rf")
    render.setup()
  end)

  describe("prompt library", function()
    it("has the default prompts", function()
      local names = vim.tbl_keys(render.prompts())
      table.sort(names)
      expect.equality(names, {
        "buffers",
        "changes",
        "class",
        "diagnostics",
        "diagnostics_all",
        "document",
        "explain",
        "file",
        "fix",
        "function",
        "line",
        "optimize",
        "position",
        "quickfix",
        "review",
        "selection",
        "tests",
      })
    end)

    it("resolves templates", function()
      local snap = snapshot.capture()
      expect.equality(render.template("explain", snap), "Explain {this}")
      expect.equality(render.template("file", snap), "{file}")
      expect.equality(
        render.template("diagnostics", snap),
        "Can you help me fix the diagnostics in {file}?\n{diagnostics}"
      )
      expect.equality(render.template("document", snap), "Add documentation to {function|line}")
    end)

    it("merges user prompts: string, table and function; false removes", function()
      render.setup({
        fix = false,
        mine = "hello {file}",
        tabled = { msg = "from table" },
        dyn = function(snap)
          return "buf " .. snap.buf
        end,
      })
      local snap = snapshot.capture()
      expect.equality(render.template("mine", snap), "hello {file}")
      expect.equality(render.template("tabled", snap), "from table")
      expect.equality(render.template("dyn", snap), "buf " .. snap.buf)
      expect.equality(select(2, render.template("fix", snap)).id, "unknown_prompt")
      expect.equality(render.template("explain", snap), "Explain {this}")
    end)

    it("a user prompt overrides a default", function()
      render.setup({ explain = "Describe {file}" })
      expect.equality(render.template("explain", snapshot.capture()), "Describe {file}")
    end)

    it("setup() with nothing resets to the defaults", function()
      render.setup({ fix = false, mine = "x" })
      render.setup()
      expect.equality(render.prompts().mine, nil)
      expect.equality(render.prompts().fix, "Can you fix {this}?")
    end)

    it("displays the raw template, <function> for function prompts", function()
      render.setup({
        tabled = { msg = "t" },
        dyn = function()
          return ""
        end,
      })
      expect.equality(render.display("explain"), "Explain {this}")
      expect.equality(render.display("tabled"), "t")
      expect.equality(render.display("dyn"), "<function>")
    end)

    it("reports a function prompt that throws as render_failed", function()
      render.setup({
        bad = function()
          error("boom")
        end,
      })
      local text, err = run({ prompt = "bad" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(err.names, { "bad" })
    end)
  end)

  describe("render", function()
    it("returns an empty string without msg or prompt", function()
      expect.equality(run({}), "")
    end)

    it("keeps a lone newline", function()
      expect.equality(run({ msg = "\n" }), "\n")
    end)

    it("puts msg lines first, then the prompt", function()
      expect.equality(run({ msg = "Hi", prompt = "changes" }), "Hi\nCan you review my changes?")
      expect.equality(run({ msg = "a\nb" }), "a\nb")
    end)

    it("reports an unknown prompt", function()
      local text, err = run({ prompt = "nope" })
      expect.equality(text, nil)
      expect.equality(err.id, "unknown_prompt")
    end)

    it("substitutes built-in placeholders", function()
      open("a.lua", { "one", "two" })
      vim.api.nvim_win_set_cursor(0, { 2, 1 })
      expect.equality(
        run({ msg = "see {file} and {line} and {position}" }),
        "see @a.lua and @a.lua :L2 and @a.lua :L2:C2"
      )
      expect.equality(run({ msg = "{file}" }, "claude"), "@a.lua")
      expect.equality(run({ msg = "{position}" }, "claude"), "@a.lua#L2 :C2")
    end)

    it("takes the first non-empty alternative", function()
      render.setup(nil, {
        empty = function() end,
        blank = function()
          return { "" }
        end,
        foo = function()
          return "FOO"
        end,
        bar = function()
          return "BAR"
        end,
      })
      expect.equality(run({ msg = "{empty|blank|foo|bar}" }), "FOO")
      expect.equality(run({ msg = "{bar|foo}" }), "BAR")
    end)

    it("falls back from {function} to {line} for the document prompt", function()
      open("a.lua", { "one" })
      expect.equality(run({ prompt = "document" }), "Add documentation to @a.lua :L1")
    end)

    it("evaluates each placeholder at most once", function()
      local calls = 0
      render.setup(nil, {
        counted = function()
          calls = calls + 1
          return "c"
        end,
        none = function()
          calls = calls + 100
        end,
      })
      expect.equality(run({ msg = "{counted} {counted} {none|counted} {counted|none}" }), "c c c c")
      expect.equality(calls, 101)
    end)

    it("accepts user sources returning a string, a list or nothing, and passes the style", function()
      local seen
      render.setup(nil, {
        list = function()
          return { "a", "b" }
        end,
        styled = function(_, ctx)
          seen = ctx.style
          return "s"
        end,
      })
      expect.equality(run({ msg = "{list}" }), "a\nb")
      run({ msg = "{styled}" }, "escaped")
      expect.equality(seen, "escaped")
    end)

    it("a user source overrides a built-in one", function()
      render.setup(nil, {
        file = function()
          return "mine"
        end,
      })
      expect.equality(run({ msg = "{file}" }), "mine")
    end)

    it("does not expand braces inside inserted values or unrelated braces", function()
      render.setup(nil, {
        code = function()
          return "local t = {file}"
        end,
      })
      expect.equality(run({ msg = "x {code} {} { a } {a b} {1+1}" }), "x local t = {file} {} { a } {a b} {1+1}")
    end)

    it("leaves a non-placeholder with a pipe alone", function()
      expect.equality(run({ msg = "{|} {a|}" }), "{|} {a|}")
    end)
  end)

  describe("failures", function()
    it("names every unknown placeholder, across alternatives", function()
      render.setup(nil, {
        known = function()
          return "k"
        end,
      })
      local text, err = run({ msg = "{known|nope} {other} {nope}" })
      expect.equality(text, nil)
      expect.equality(err.id, "unknown_context")
      expect.equality(err.names, { "nope", "other" })
    end)

    it("names the empty placeholder expressions", function()
      render.setup(nil, {
        none = function() end,
        full = function()
          return "x"
        end,
      })
      local text, err = run({ msg = "{full} {none} {none|none} {full}" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(err.names, { "none", "none|none" })
    end)

    it("fails the whole render when one placeholder is empty", function()
      open("a.lua", { "one" })
      local text, err = run({ msg = "{file} {selection}" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(err.names, { "selection" })
    end)

    it("names the function placeholder when no textobjects query exists", function()
      open("a.lua", { "one" })
      vim.bo.filetype = "lua"
      local text, err = run({ msg = "{function}" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(err.names, { "function" })
    end)

    it("counts a throwing source as empty and keeps the detail", function()
      render.setup(nil, {
        boom = function()
          error("kaput")
        end,
      })
      local text, err = run({ msg = "{boom}" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(err.names, { "boom" })
      expect.equality(type(err.detail), "string")
    end)

    it("fails the diagnostics prompt when there are no diagnostics", function()
      open("a.lua", { "one" })
      local _, err = run({ prompt = "diagnostics" })
      expect.equality(err.id, "render_failed")
      expect.equality(err.names, { "diagnostics" })
    end)
  end)

  describe("{this}", function()
    it("becomes the position in a file buffer", function()
      open("a.lua", { "one", "two" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      expect.equality(run({ prompt = "explain" }), "Explain @a.lua :L2:C1")
      expect.equality(run({ prompt = "explain" }, "claude"), "Explain @a.lua#L2 :C1")
    end)

    it("becomes the selected range in a file buffer", function()
      open("a.lua", { "one", "two", "three" })
      vim.cmd("normal! ggVj")
      expect.equality(run({ prompt = "fix" }), "Can you fix @a.lua :L1-L2?")
    end)

    it("is the word this plus the selection outside a file buffer", function()
      scratch({ "alpha", "beta" })
      vim.cmd("normal! ggVj")
      expect.equality(run({ prompt = "explain" }), "Explain this\n\nalpha\nbeta")
    end)

    it("appends the selection once even when this appears twice", function()
      scratch({ "alpha" })
      vim.cmd("normal! ggV")
      expect.equality(run({ msg = "{this} and {this}" }), "this and this\n\nalpha")
    end)

    it("does not expand braces inside the appended selection", function()
      scratch({ "t = {file}" })
      vim.cmd("normal! ggV")
      expect.equality(run({ msg = "{this}" }), "this\n\nt = {file}")
    end)

    it("fails naming selection outside a file buffer without a selection", function()
      scratch({ "alpha" })
      local text, err = run({ prompt = "explain" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(err.names, { "selection" })
    end)
  end)
end)
