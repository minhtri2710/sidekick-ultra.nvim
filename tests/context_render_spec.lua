local expect = MiniTest.expect
local location = require("sidekick-ultra.location")
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
    local segments, err = render.build(opts, snapshot.capture())
    if not segments then
      return nil, err
    end
    return location.format(segments, style)
  end

  ---Whether the message of `err` holds every token of `has` and none of `lacks`.
  ---@param err sidekick_ultra.Error
  ---@param has string[]
  ---@param lacks? string[]
  ---@return boolean
  local function says(err, has, lacks)
    local function holds(token)
      return err.msg:find(token, 1, true) ~= nil
    end
    return vim.iter(has):all(holds) and not vim.iter(lacks or {}):any(holds)
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
      -- Placeholders derive a bare `{name}` prompt only where no explicit text exists.
      expect.equality(render.prompts().file, "{file}")
      -- Each explicit default prompt names the context it sends; its wording is not pinned.
      local placeholders = {
        changes = {},
        diagnostics = { "file", "diagnostics" },
        diagnostics_all = { "diagnostics_all" },
        document = { "function|line" },
        explain = { "this" },
        fix = { "this" },
        optimize = { "this" },
        review = { "file" },
        tests = { "this" },
      }
      for name, expected in pairs(placeholders) do
        local found = {}
        for expr in render.prompts()[name]:gmatch("{([^{}]*)}") do
          table.insert(found, expr)
        end
        expect.equality({ name, found }, { name, expected })
      end
    end)

    it("merges user prompts: string, table and function; false removes", function()
      open("a.lua", { "one" })
      render.setup({
        fix = false,
        mine = "hello {file}",
        tabled = { msg = "from table" },
        dyn = function(snap)
          return "buf " .. snap.buf
        end,
      })
      expect.equality(run({ prompt = "mine" }), "hello @a.lua")
      expect.equality(run({ prompt = "tabled" }), "from table")
      expect.equality(run({ prompt = "dyn" }), "buf " .. vim.api.nvim_get_current_buf())
      local text, err = run({ prompt = "fix" })
      expect.equality({ text, err.id }, { nil, "unknown_prompt" })
      expect.equality(render.prompts().explain ~= nil, true)
    end)

    it("a user prompt overrides a default", function()
      open("a.lua", { "one" })
      render.setup({ explain = "Describe {file}" })
      expect.equality(run({ prompt = "explain" }), "Describe @a.lua")
    end)

    it("setup() with nothing resets to the defaults", function()
      render.setup({ fix = false, mine = "x" })
      render.setup()
      expect.equality(render.prompts().mine, nil)
      expect.equality(render.prompts().fix, render.default_prompts.fix)
    end)

    it("reports a function prompt that throws as render_failed", function()
      render.setup({
        bad = function()
          error("boom\nsecond line")
        end,
      })
      local text, err = run({ prompt = "bad" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(says(err, { "bad", "boom" }, { "second line", "\n" }), true)
    end)
  end)

  describe("render", function()
    it("returns nothing, and no error, when the text is empty", function()
      local snap = snapshot.capture()
      expect.equality({ render.build({}, snap) }, {})
      expect.equality({ render.build({ msg = "" }, snap) }, {})
      render.setup({ blank = "" })
      expect.equality({ render.build({ prompt = "blank" }, snap) }, {})
    end)

    it("keeps a lone newline", function()
      expect.equality(run({ msg = "\n" }), "\n")
    end)

    it("makes the message {selection} when there is a selection and neither msg nor prompt", function()
      scratch({ "alpha", "beta" })
      vim.cmd("normal! ggVj")
      expect.equality(run({}), "alpha\nbeta")
    end)

    it("does not default to the selection when there is a msg or a prompt", function()
      scratch({ "alpha", "beta" })
      vim.cmd("normal! ggVj")
      expect.equality(run({ msg = "hi" }), "hi")
      render.setup({ mine = "from the prompt" })
      expect.equality(run({ prompt = "mine" }), "from the prompt")
    end)

    it("puts msg lines first, then the prompt", function()
      render.setup({ mine = "from the prompt" })
      expect.equality(run({ msg = "Hi", prompt = "mine" }), "Hi\nfrom the prompt")
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
        wrong = function()
          return 5
        end,
        foo = function()
          return "FOO"
        end,
        bar = function()
          return "BAR"
        end,
      })
      expect.equality(run({ msg = "{empty|blank|wrong|foo|bar}" }), "FOO")
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

    it("writes one build out in each style", function()
      local file = vim.fn.tempname() .. "/my file.lua"
      vim.fn.mkdir(vim.fs.dirname(file), "p")
      vim.fn.writefile({ "x" }, file)
      vim.cmd.edit(file)
      local segments = render.build({ msg = "see {file}" }, snapshot.capture())
      expect.equality(location.format(segments, "plain"), "see @" .. location.path(0, snapshot.capture().cwd))
      expect.equality(location.format(segments, "claude"):find('@"', 1, true) ~= nil, true)
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
        present = function()
          return "k"
        end,
      })
      local text, err = run({ msg = "{present|nope} {other} {nope}" })
      expect.equality(text, nil)
      expect.equality(err.id, "unknown_context")
      expect.equality(says(err, { "nope", "other" }, { "present" }), true)
      expect.equality(select(2, err.msg:gsub("nope", "")), 1)
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
      expect.equality(says(err, { "for: none, none|none" }, { "full" }), true)
    end)

    it("fails the whole render when one placeholder is empty", function()
      open("a.lua", { "one" })
      local text, err = run({ msg = "{file} {selection}" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(says(err, { "selection" }, { "file" }), true)
    end)

    it("names the function placeholder when no textobjects query exists", function()
      open("a.lua", { "one" })
      vim.bo.filetype = "lua"
      local text, err = run({ msg = "{function}" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(says(err, { "function" }), true)
    end)

    it("keeps the cause when a textobjects query has no parser", function()
      vim.treesitter.query.set("zzz", "textobjects", "(x) @function.outer")
      MiniTest.finally(function()
        vim.treesitter.query.set("zzz", "textobjects", "")
      end)
      open("a.zzz", { "x" })
      vim.bo.filetype = "zzz"
      local text, err = run({ msg = "{function}" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(says(err, { "(function: ", "zzz" }), true)
    end)

    it("counts a throwing source as empty and keeps the first line of the cause", function()
      render.setup(nil, {
        boom = function()
          error("kaput\nsecond line")
        end,
      })
      local text, err = run({ msg = "{boom}" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(says(err, { "(boom: ", "kaput" }, { "second line", "\n" }), true)
    end)

    it("names the cause of a source only for the expressions that failed, once", function()
      render.setup(nil, {
        boom = function()
          error("kaput")
        end,
        full = function()
          return "x"
        end,
        none = function() end,
      })
      local _, rescued = run({ msg = "{boom|full} {none}" })
      expect.equality(says(rescued, { "for: none" }, { "boom", "kaput" }), true)

      local _, twice = run({ msg = "{boom} {boom|none}" })
      expect.equality(select(2, twice.msg:gsub("kaput", "")), 1)

      local _, later = run({ msg = "{none|boom}" })
      expect.equality(says(later, { "for: none|boom", "(boom: ", "kaput" }), true)
    end)

    it("counts false and an empty list as nothing, with no cause", function()
      for name, value in pairs({ off = false, no_lines = {} }) do
        render.setup(nil, {
          [name] = function()
            return value
          end,
        })
        local text, err = run({ msg = "{" .. name .. "}" })
        expect.equality(text, nil)
        expect.equality(err.id, "render_failed")
        expect.equality(says(err, { "for: " .. name }, { "(" .. name .. ": " }), true)
      end
    end)

    it("counts a source returning a malformed value as empty and keeps the cause", function()
      local mixed = { "a" }
      mixed.n = 1
      local bad = {
        number = 5,
        yes = true,
        dict = { lnum = 1 },
        mixed = mixed,
        func = function() end,
        numbers = { 1, 2 },
        empty_table = { { {} } },
        no_kind = { { { path = "x" } } },
        no_row = { { { path = "x", kind = "line" } } },
        dicts = { { lnum = 1, text = "a" }, { lnum = 2, text = "b" } },
      }
      for name, value in pairs(bad) do
        render.setup(nil, {
          [name] = function()
            return value
          end,
        })
        local ok, text, err = pcall(run, { msg = "{" .. name .. "}" })
        expect.equality(ok, true)
        expect.equality(text, nil)
        expect.equality(err.id, "render_failed")
        expect.equality(says(err, { "(" .. name .. ": " }, { "render.lua:" }), true)
      end
    end)

    it("fails the diagnostics prompt when there are no diagnostics", function()
      open("a.lua", { "one" })
      local _, err = run({ prompt = "diagnostics" })
      expect.equality(err.id, "render_failed")
      expect.equality(says(err, { "diagnostics" }), true)
    end)
  end)

  describe("{this}", function()
    before_each(function()
      render.setup({ about = "About {this}" })
    end)

    it("becomes the position in a file buffer", function()
      open("a.lua", { "one", "two" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      expect.equality(run({ prompt = "about" }), "About @a.lua :L2:C1")
      expect.equality(run({ prompt = "about" }, "claude"), "About @a.lua#L2 :C1")
    end)

    it("becomes the selected range in a file buffer", function()
      open("a.lua", { "one", "two", "three" })
      vim.cmd("normal! ggVj")
      expect.equality(run({ prompt = "about" }), "About @a.lua :L1-L2")
    end)

    it("is the word this plus the selection outside a file buffer", function()
      scratch({ "alpha", "beta" })
      vim.cmd("normal! ggVj")
      expect.equality(run({ prompt = "about" }), "About this\n\nalpha\nbeta")
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

    it("is not a source: it cannot be an alternative", function()
      open("a.lua", { "one" })
      local text, err = run({ msg = "{this|file}" })
      expect.equality(text, nil)
      expect.equality({ err.id, says(err, { "this" }, { "file" }) }, { "unknown_context", true })
    end)

    it("fails naming selection outside a file buffer without a selection", function()
      scratch({ "alpha" })
      local text, err = run({ prompt = "about" })
      expect.equality(text, nil)
      expect.equality(err.id, "render_failed")
      expect.equality(says(err, { "selection" }), true)
    end)
  end)
end)
