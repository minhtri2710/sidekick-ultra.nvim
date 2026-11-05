---sidekick-ultra.nvim: drive AI CLIs that run in herdr panes, rex blocks, tmux panes or zellij panes.
local M = {}

local BACKENDS = { "herdr", "rex", "tmux", "zellij" }

---Validate the options, register the enabled and available backends, create `:SidekickUltra` and define the default
---keymaps. Raises an error naming the key path when the options are invalid. Calling it again first detaches every
---attached session (the detach events fire), replaces the keymaps and starts from a clean state.
---@param opts? table see `sidekick_ultra.Config`
function M.setup(opts)
  local cfg = require("sidekick-ultra.config").setup(opts)
  require("sidekick-ultra.tools").setup(cfg.tools)
  require("sidekick-ultra.context.render").setup(cfg.prompts, cfg.context)
  local registry = require("sidekick-ultra.registry")
  registry.detach_all()
  registry.reset()
  for _, name in ipairs(BACKENDS) do
    if cfg[name].enabled then
      local backend = require("sidekick-ultra.backends." .. name)
      if backend.available() then
        registry.register(backend)
      end
    end
  end
  require("sidekick-ultra.command").setup()
  require("sidekick-ultra.keys").setup(cfg.keys)
  require("sidekick-ultra.status").setup()
end

---Render a message or prompt and send it to the target session. See `sidekick_ultra.ActionOpts`.
---@param opts? sidekick_ultra.ActionOpts
function M.send(opts)
  require("sidekick-ultra.actions").send(opts)
end

---Pick a prompt from the library and send it.
---@param opts? sidekick_ultra.ActionOpts
function M.prompt(opts)
  require("sidekick-ultra.actions").prompt(opts)
end

---Pick a session or tool and attach it. A tool that is started is focused unless `focus = false`.
---@param opts? sidekick_ultra.ActionOpts
function M.select(opts)
  require("sidekick-ultra.actions").select(opts)
end

---Focus the target session's pane or block.
---@param opts? sidekick_ultra.ActionOpts
function M.focus(opts)
  require("sidekick-ultra.actions").focus(opts)
end

---Detach attached sessions. The tool keeps running.
---@param opts? sidekick_ultra.ActionOpts
function M.close(opts)
  require("sidekick-ultra.actions").close(opts)
end

---Render without sending.
---@param opts? sidekick_ultra.ActionOpts
---@return string? text
---@return sidekick_ultra.Error? err
function M.render(opts)
  return require("sidekick-ultra.actions").render(opts)
end

return M
