---The default keymaps: one table, used both to define the maps (`setup`) and to list lazy.nvim key triggers
---(`triggers`). It has no top-level `require`, so `lazy.lua` can `dofile` it before the plugin is on the runtimepath.
local M = {}

M.DEFAULT_PREFIX = "<leader>a"

local function api()
  return require("sidekick-ultra")
end

---`action` is nil for the prefix entry, which only carries a `desc` for which-key style menus.
---@type { suffix: string, modes: string[], desc: string, action?: fun() }[]
local KEYS = {
  { suffix = "", modes = { "n", "x" }, desc = "+sidekick-ultra" },
  {
    suffix = "s",
    modes = { "n" },
    desc = "Select Session",
    action = function()
      api().select()
    end,
  },
  {
    suffix = "t",
    modes = { "n", "x" },
    desc = "Send This",
    action = function()
      api().send({ msg = "{this}" })
    end,
  },
  {
    suffix = "f",
    modes = { "n" },
    desc = "Send File",
    action = function()
      api().send({ msg = "{file}" })
    end,
  },
  {
    suffix = "v",
    modes = { "x" },
    desc = "Send Selection",
    action = function()
      api().send({ msg = "{selection}" })
    end,
  },
  {
    suffix = "p",
    modes = { "n", "x" },
    desc = "Select Prompt",
    action = function()
      api().prompt()
    end,
  },
  {
    suffix = "o",
    modes = { "n" },
    desc = "Focus Session",
    action = function()
      api().focus()
    end,
  },
  {
    suffix = "d",
    modes = { "n" },
    desc = "Detach Session",
    action = function()
      api().close()
    end,
  },
}

local function noop() end

---The maps `setup` defined last: `{ mode, lhsraw, rhs }`, with `lhsraw` as `maparg` reports it right after the set (`<leader>` expanded).
---@type { [1]: string, [2]: string, [3]: function }[]
local defined = {}

---The global (never buffer-local) map in `mode` whose raw lhs is `lhsraw`, or nil.
---@param mode string
---@param lhsraw string
---@return table?
local function global(mode, lhsraw)
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if m.lhsraw == lhsraw then
      return m
    end
  end
end

---lazy.nvim key specs (lhs, mode, desc; no rhs) for a prefix.
---@param prefix string
---@return LazyKeysSpec[]
function M.triggers(prefix)
  return vim.tbl_map(function(key)
    -- selene: allow(mixed_table)
    return { prefix .. key.suffix, mode = key.modes, desc = key.desc }
  end, KEYS)
end

---Delete the maps the previous `setup` defined, then define the new set: `{ prefix = string }`, or false for none.
---A map the user has since replaced, and any buffer-local map, is left alone.
---@param cfg { prefix: string }|false
function M.setup(cfg)
  for _, map in ipairs(defined) do
    local mode, lhsraw, rhs = unpack(map)
    local m = global(mode, lhsraw)
    if m and m.callback == rhs then
      vim.keymap.del(mode, m.lhs)
    end
  end
  defined = {}
  if not cfg then
    return
  end
  for _, key in ipairs(KEYS) do
    local rhs = key.action or noop
    for _, mode in ipairs(key.modes) do
      local lhs = cfg.prefix .. key.suffix
      vim.keymap.set(mode, lhs, rhs, { desc = key.desc })
      -- A buffer-local map at the same lhs shadows the global one here but has the same lhsraw.
      table.insert(defined, { mode, vim.fn.maparg(lhs, mode, false, true).lhsraw, rhs })
    end
  end
end

return M
