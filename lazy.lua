-- lazy.nvim reads this file when it installs or updates the plugin. It adds the default keymaps as key triggers
-- (lhs, mode, desc; no rhs), so they exist before the plugin loads. lazy.nvim deletes the trigger on press, loads
-- the plugin, whose `setup()` defines the real map, and replays the key.
return {
  "minhtri2710/sidekick-ultra.nvim",
  keys = function(plugin, keys)
    local opts = require("lazy.core.plugin").values(plugin, "opts", false)
    -- The plugin is not on the runtimepath yet, so keys.lua is loaded by path; it has no top-level `require`.
    local keymaps = dofile(plugin.dir .. "/lua/sidekick-ultra/keys.lua")
    -- No triggers for `keys = false`, nor for an invalid option, which `setup()` rejects.
    local cfg = keymaps.resolve(opts.keys)
    if not cfg then
      return keys
    end
    return vim.list_extend(keys, keymaps.triggers(cfg.prefix))
  end,
}
