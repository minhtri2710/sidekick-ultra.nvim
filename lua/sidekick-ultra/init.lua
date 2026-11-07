---sidekick-ultra.nvim: drive AI CLIs that run in the panes or blocks of a terminal multiplexer (the backends).
local actions = require("sidekick-ultra.actions")

local M = {}

---Validate the options, register the enabled and available backends, create `:SidekickUltra` and define the default
---keymaps. Raises an error naming the key path when the options are invalid. Calling it again first detaches every
---attached session (the detach events fire), replaces the keymaps and starts from a clean state.
---@param opts? table see `sidekick_ultra.Config`
function M.setup(opts)
  local cfg = require("sidekick-ultra.config").setup(opts)
  require("sidekick-ultra.tools").setup(cfg.tools)
  require("sidekick-ultra.context.render").setup(cfg.prompts, cfg.context)
  local registry = require("sidekick-ultra.registry")
  registry.reset()
  for _, info in ipairs(require("sidekick-ultra.backends").all) do
    if cfg[info.name].enabled then
      local backend = require("sidekick-ultra.backends." .. info.name)
      if backend.setup then
        backend.setup(cfg[info.name])
      end
      if backend.available() then
        registry.register(backend)
      end
    end
  end
  require("sidekick-ultra.command").setup()
  require("sidekick-ultra.keys").setup(cfg.keys)
  require("sidekick-ultra.status").setup()
  require("sidekick-ultra.watch").setup(cfg.watch)
end

M.send = actions.send
M.prompt = actions.prompt
M.select = actions.select
M.focus = actions.focus
M.close = actions.close
M.render = actions.render

return M
