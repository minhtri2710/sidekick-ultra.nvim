local picker = require("sidekick-ultra.picker")
local ui = require("tests.helpers.ui")

local expect = MiniTest.expect

describe("picker", function()
  local pick, orig_columns, orig_lines

  before_each(function()
    pick = ui.capture(function() end)
    orig_columns, orig_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 80, 24
  end)
  after_each(function()
    vim.o.columns, vim.o.lines = orig_columns, orig_lines
    pick.restore()
  end)

  ---Open the picker over `prompts` (name -> text, or a function giving the text, shown as `<function>`) and return what
  ---it asked for.
  local function open(prompts)
    local names = vim.tbl_keys(prompts)
    table.sort(names)
    local items = vim.tbl_map(function(name)
      local prompt = prompts[name]
      if type(prompt) == "function" then
        return { name = name, display = "<function>", preview = { text = prompt() } }
      end
      return { name = name, display = prompt, preview = { text = prompt } }
    end, names)
    picker.select(items, function() end)
    return pick.selects[#pick.selects]
  end

  ---The sizes the picker asks snacks for when only `prompts` are listed.
  local function sizes(prompts)
    local box = open(prompts).opts.snacks.layout.layout
    return { width = box.width, height = box.height, list = box[2].height, preview = box[3].height }
  end

  local function many(n, extra)
    local prompts = vim.tbl_extend("force", {}, extra or {})
    for i = 1, n do
      prompts[("p%02d"):format(i)] = "x"
    end
    return prompts
  end

  local function lines_of(n)
    return table.concat(vim.fn["repeat"]({ "x" }, n), "\n")
  end

  it("passes the snacks preview option with the preview pane shown", function()
    local snacks = open({ a = "Hi" }).opts.snacks
    expect.equality(snacks.preview, "preview")
    local box = snacks.layout.layout
    expect.equality({ box[1].win, box[2].win, box[3].win }, { "input", "list", "preview" })
    expect.equality(#box, 3)
    expect.equality(snacks.layout.hidden, nil)
  end)

  it("labels an item with its name and its display text, newlines shown as \\n", function()
    local select = open({ diagnostics_all = "Can you help me fix these diagnostics?\n{diagnostics_all}" })
    expect.equality(
      select.opts.format_item(select.items[1]),
      "diagnostics_all    Can you help me fix these diagnostics?\\n{diagnostics_all}"
    )
  end)

  it("passes the user's choice on", function()
    local chosen
    pick.choose = function(items)
      return items[1]
    end
    picker.select({ { name = "a", display = "Hi", preview = { text = "Hi" } } }, function(item)
      chosen = item.name
    end)
    expect.equality(chosen, "a")
  end)

  describe("size", function()
    it("is small for a short prompt: the minimum width, two list rows, one preview row", function()
      expect.equality(sizes({ a = "Hi" }), { width = 40, height = 6, list = 2, preview = 1 })
    end)

    it("grows with the list label and the preview text, up to the width cap", function()
      expect.equality(sizes({ mid = ("x"):rep(30) }), { width = 52, height = 6, list = 2, preview = 1 })
      expect.equality(sizes({ long = ("word "):rep(60) }), { width = 72, height = 6, list = 2, preview = 1 })
    end)

    it("gives a preview that does not wrap one row per line, however long the lines", function()
      local line = ("word "):rep(60)
      local text = table.concat(vim.fn["repeat"]({ line }, 15), "\n")
      vim.o.lines = 40
      expect.equality(sizes({ diag = text }), { width = 72, height = 20, list = 2, preview = 15 })
    end)

    it("stops the width at the inner width of snacks' own select picker", function()
      local long = { long = ("word "):rep(60) }
      for columns, width in pairs({ [120] = 80, [200] = 98, [300] = 100 }) do
        vim.o.columns = columns
        expect.equality(sizes(long).width, width)
      end
      vim.o.columns = 200
      expect.equality(sizes({ mid = ("x"):rep(30) }).width, 52)
    end)

    it("turns the preview's wrap off, whatever the user's option", function()
      expect.equality(open({ a = "Hi" }).opts.snacks.win.preview.wo.wrap, false)
    end)

    it("sizes the preview for the item that needs the most rows", function()
      expect.equality(sizes({ a = "Hi", b = "one\ntwo\nthree" }), { width = 40, height = 8, list = 2, preview = 3 })
    end)

    it("reads the columns when the picker opens, and keeps the width under them", function()
      vim.o.columns = 84
      expect.equality(sizes({ long = ("word "):rep(60) }).width, 76)
      vim.o.columns = 44
      expect.equality(sizes({ long = ("word "):rep(60) }).width, 36)
    end)

    it("caps the preview at half the lines", function()
      expect.equality(sizes({ tall = lines_of(40) }), { width = 72, height = 17, list = 2, preview = 12 })
    end)

    it("grows the list with the items, between 2 and 10 rows", function()
      expect.equality(sizes(many(1)).list, 2)
      expect.equality(sizes(many(5)).list, 5)
      expect.equality(sizes(many(12)), { width = 40, height = 14, list = 10, preview = 1 })
    end)

    it("keeps the box 4 rows short of the screen, taking the rows from the preview", function()
      expect.equality(sizes(many(12, { tall = lines_of(40) })), { width = 72, height = 20, list = 10, preview = 7 })
    end)

    it("keeps the list at 2 rows, and the box 4 rows short, on the smallest screen that holds them", function()
      vim.o.lines = 10
      expect.equality(sizes(many(12, { tall = lines_of(40) })), { width = 72, height = 6, list = 2, preview = 1 })
    end)

    it("shrinks the list to 1 row, rather than pass 4 rows short, on a screen one row smaller", function()
      vim.o.lines = 9
      expect.equality(sizes(many(12, { tall = lines_of(40) })), { width = 72, height = 5, list = 1, preview = 1 })
    end)

    it("keeps the 5-row floor (list 1, preview 1) on a screen too short for it", function()
      vim.o.lines = 8
      expect.equality(sizes(many(12)), { width = 40, height = 5, list = 1, preview = 1 })
    end)

    it("counts the number column in the width", function()
      -- The label of a function prompt is "<function>", so the preview line is the widest text.
      expect.equality(
        sizes({
          f = function()
            return ("x"):rep(60)
          end,
        }).width,
        64
      )
    end)

    it("measures the width in display cells, not bytes", function()
      local wide = vim.fn.nr2char(0x3042):rep(30)
      expect.equality(
        sizes({
          f = function()
            return wide
          end,
        }).width,
        64
      )
    end)
  end)
end)
