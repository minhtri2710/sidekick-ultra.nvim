-- lazy.nvim reads this file when it installs or updates the plugin. It adds the default keymaps as key triggers
-- (lhs, mode, desc; no rhs), so they exist before the plugin loads. lazy.nvim deletes the trigger on press, loads
-- the plugin, whose `setup()` defines the real map, and replays the key.
return {
  "minhtri2710/sidekick-ultra.nvim",
  keys = function(plugin, keys)
    local opts = require("lazy.core.plugin").values(plugin, "opts", false)
    local keymaps = dofile(plugin.dir .. "/lua/sidekick-ultra/keys.lua")
    local cfg = opts.keys == nil and {} or opts.keys
    local prefix = type(cfg) == "table" and (cfg.prefix == nil and keymaps.DEFAULT_PREFIX or cfg.prefix)
    if type(prefix) ~= "string" or prefix == "" then
      return keys
    end
    return vim.list_extend(keys, keymaps.triggers(prefix))
  end,
}
