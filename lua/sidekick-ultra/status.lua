---Statusline data. Never runs an external command: a refresh only runs the cheap `is_running` checks.
local registry = require("sidekick-ultra.registry")

local M = {}

local MAX_AGE_MS = 5000

---@class sidekick_ultra.StatusItem
---@field id string
---@field tool string
---@field cwd string
---@field backend string
---@field state? sidekick_ultra.AgentState

---@type sidekick_ultra.StatusItem[]
local items = {}
local refreshed_at = nil

function M.refresh()
  items = vim.tbl_map(function(session)
    return { id = session.id, tool = session.tool, cwd = session.cwd, backend = session.backend, state = session.state }
  end, registry.attached())
  refreshed_at = vim.uv.now()
end

---One entry per attached session. Refreshed on attach and detach, and when older than 5 s (which also detaches
---sessions that stopped running).
---@return sidekick_ultra.StatusItem[]
function M.cli()
  if not refreshed_at or vim.uv.now() - refreshed_at > MAX_AGE_MS then
    M.refresh()
  end
  return items
end

---Forget the cache (tests).
function M.reset()
  items = {}
  refreshed_at = nil
end

function M.setup()
  local group = vim.api.nvim_create_augroup("sidekick-ultra-status", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { registry.ATTACH, registry.DETACH },
    callback = M.refresh,
  })
end

return M
