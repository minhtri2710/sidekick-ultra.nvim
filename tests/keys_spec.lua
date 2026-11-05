local actions = require("sidekick-ultra.actions")
local fake = require("tests.helpers.fake")
local keys = require("sidekick-ultra.keys")
local sidekick = require("sidekick-ultra")

local expect = MiniTest.expect

local ROOT = vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))))

-- The seven maps of behavior section 5: suffix, modes, desc, the action called and its arguments.
local TABLE = {
  { "s", { "n" }, "Select Session", "select", {} },
  { "t", { "n", "x" }, "Send This", "send", { { msg = "{this}" } } },
  { "f", { "n" }, "Send File", "send", { { msg = "{file}" } } },
  { "v", { "x" }, "Send Selection", "send", { { msg = "{selection}" } } },
  { "p", { "n", "x" }, "Select Prompt", "prompt", {} },
  { "o", { "n" }, "Focus Session", "focus", {} },
  { "d", { "n" }, "Detach Session", "close", {} },
}
local PREFIX_DESC = "+sidekick-ultra"

---@return table map the global map for lhs in mode, or {}
local function map(mode, lhs)
  return vim.fn.maparg(lhs, mode, false, true)
end

---Every global n/x map the plugin owns, found by its desc (the prefix and the seven of behavior section 5: 11 in all).
local function ours()
  local descs = { [PREFIX_DESC] = true }
  for _, row in ipairs(TABLE) do
    descs[row[3]] = true
  end
  local ret = {}
  for _, mode in ipairs({ "n", "x" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      if descs[m.desc] then
        table.insert(ret, m)
      end
    end
  end
  return ret
end

describe("keys", function()
  local calls, orig
  before_each(function()
    fake.reset()
    calls = {}
    orig = {}
    for _, name in ipairs({ "select", "send", "prompt", "focus", "close" }) do
      orig[name] = actions[name]
      actions[name] = function(...)
        table.insert(calls, { name, ... })
      end
    end
  end)
  after_each(function()
    for name, fn in pairs(orig) do
      actions[name] = fn
    end
    keys.setup(false)
  end)

  describe("setup()", function()
    it("defines the seven maps with their desc, each calling the public API", function()
      sidekick.setup({ herdr = { enabled = false }, rex = { enabled = false } })
      for _, row in ipairs(TABLE) do
        local suffix, modes, desc, action, args = unpack(row)
        for _, mode in ipairs(modes) do
          local m = map(mode, "<leader>a" .. suffix)
          expect.equality(m.desc, desc)
          calls = {}
          m.callback()
          expect.equality(calls, { { action, unpack(args) } })
        end
      end
    end)

    it("defines the prefix with its desc and no action, and nothing else", function()
      sidekick.setup({ herdr = { enabled = false }, rex = { enabled = false } })
      for _, mode in ipairs({ "n", "x" }) do
        expect.equality(map(mode, "<leader>a").desc, PREFIX_DESC)
      end
      calls = {}
      map("n", "<leader>a").callback()
      expect.equality(calls, {})
      expect.equality(#ours(), 11)
    end)

    it("moves every map to another prefix and leaves none at the default", function()
      sidekick.setup({ keys = { prefix = "<leader>S" }, herdr = { enabled = false }, rex = { enabled = false } })
      for _, row in ipairs(TABLE) do
        for _, mode in ipairs(row[2]) do
          expect.equality(map(mode, "<leader>S" .. row[1]).desc, row[3])
          expect.equality(map(mode, "<leader>a" .. row[1]), {})
        end
      end
      expect.equality(map("n", "<leader>S").desc, PREFIX_DESC)
      expect.equality(map("n", "<leader>a"), {})
      expect.equality(#ours(), 11)
    end)

    it("defines none for keys = false", function()
      sidekick.setup({ keys = false, herdr = { enabled = false }, rex = { enabled = false } })
      expect.equality(#ours(), 0)
    end)

    it("removes the previous set on a second setup, and leaves the user's own maps alone", function()
      local mine = function() end
      vim.keymap.set("n", "<leader>Zz", mine, { desc = "mine" })
      sidekick.setup({ herdr = { enabled = false }, rex = { enabled = false } })
      sidekick.setup({ keys = { prefix = "<leader>S" }, herdr = { enabled = false }, rex = { enabled = false } })
      expect.equality(#ours(), 11)
      expect.equality(map("n", "<leader>as"), {})
      expect.equality(map("n", "<leader>Ss").desc, "Select Session")
      expect.equality(map("n", "<leader>Zz").callback == mine, true)
      vim.keymap.del("n", "<leader>Zz")
    end)

    it("does not delete a plugin map the user has replaced", function()
      local mine = function() end
      sidekick.setup({ herdr = { enabled = false }, rex = { enabled = false } })
      vim.keymap.set("n", "<leader>as", mine, { desc = "mine" })
      sidekick.setup({ keys = false, herdr = { enabled = false }, rex = { enabled = false } })
      expect.equality(map("n", "<leader>as").callback == mine, true)
      expect.equality(map("n", "<leader>at"), {})
      vim.keymap.del("n", "<leader>as")
    end)

    it("keeps the previous maps when the options are invalid", function()
      sidekick.setup({ herdr = { enabled = false }, rex = { enabled = false } })
      expect.equality(pcall(sidekick.setup, { keys = { prefix = "" } }), false)
      expect.equality(map("n", "<leader>as").desc, "Select Session")
    end)
  end)

  describe("lazy.lua", function()
    local saved
    before_each(function()
      saved = package.loaded["lazy.core.plugin"]
    end)
    after_each(function()
      package.loaded["lazy.core.plugin"] = saved
    end)

    ---Run the spec's `keys` function the way lazy.nvim does, with `opts` as the merged opts.
    ---@return { lhs: string, mode: string[], desc: string, rhs: any }[] triggers the entries the function added
    local function triggers(opts)
      package.loaded["lazy.core.plugin"] = {
        values = function(plugin, prop, is_list)
          expect.equality({ plugin.dir, prop, is_list }, { ROOT, "opts", false })
          return opts
        end,
      }
      local spec = dofile(ROOT .. "/lazy.lua")
      expect.equality(spec[1], "minhtri2710/sidekick-ultra.nvim")
      local ret = spec.keys({ dir = ROOT }, { { "<leader>x" } })
      expect.equality(ret[1], { "<leader>x" })
      return vim.tbl_map(function(t)
        return { lhs = t[1], mode = t.mode, desc = t.desc, rhs = t[2] }
      end, vim.list_slice(ret, 2))
    end

    it("lists the triggers for the default prefix: lhs, mode, desc", function()
      local list = triggers({})
      expect.equality(list, {
        { lhs = "<leader>a", mode = { "n", "x" }, desc = PREFIX_DESC },
        { lhs = "<leader>as", mode = { "n" }, desc = "Select Session" },
        { lhs = "<leader>at", mode = { "n", "x" }, desc = "Send This" },
        { lhs = "<leader>af", mode = { "n" }, desc = "Send File" },
        { lhs = "<leader>av", mode = { "x" }, desc = "Send Selection" },
        { lhs = "<leader>ap", mode = { "n", "x" }, desc = "Select Prompt" },
        { lhs = "<leader>ao", mode = { "n" }, desc = "Focus Session" },
        { lhs = "<leader>ad", mode = { "n" }, desc = "Detach Session" },
      })
    end)

    it("uses the prefix from opts.keys", function()
      local list = triggers({ keys = { prefix = "<leader>S" } })
      expect.equality(#list, 8)
      for _, t in ipairs(list) do
        expect.equality(vim.startswith(t.lhs, "<leader>S"), true)
      end
    end)

    it("adds nothing for opts.keys = false", function()
      expect.equality(triggers({ keys = false }), {})
    end)

    it("adds nothing for an invalid prefix, which setup() then rejects", function()
      expect.equality(triggers({ keys = { prefix = 3 } }), {})
      expect.equality(triggers({ keys = { prefix = "" } }), {})
      expect.equality(triggers({ keys = { prefix = false } }), {})
      expect.equality(triggers({ keys = true }), {})
    end)

    it("gives no trigger a rhs", function()
      for _, t in ipairs(triggers({})) do
        expect.equality(t.rhs, nil)
      end
    end)

    it("declares exactly the lhs and modes that setup() defines", function()
      for _, opts in ipairs({ {}, { keys = { prefix = "<leader>S" } } }) do
        sidekick.setup(vim.tbl_extend("force", opts, { herdr = { enabled = false }, rex = { enabled = false } }))
        local count = 0
        for _, t in ipairs(triggers(opts)) do
          for _, mode in ipairs(t.mode) do
            expect.equality(map(mode, t.lhs).desc, t.desc)
            count = count + 1
          end
        end
        expect.equality(count, #ours())
      end
    end)
  end)
end)
