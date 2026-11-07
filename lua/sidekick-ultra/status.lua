---Statusline data: the attached sessions, cached. The cache follows the attach and detach events and runs the
---liveness check (`registry.check`) when it is older than `MAX_AGE_MS`.
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

local function refresh()
  items = vim.tbl_map(function(session)
    return { id = session.id, tool = session.tool, cwd = session.cwd, backend = session.backend, state = session.state }
  end, registry.attached())
  refreshed_at = vim.uv.now()
end

---@return sidekick_ultra.StatusItem[]
function M.cli()
  if not refreshed_at or vim.uv.now() - refreshed_at > MAX_AGE_MS then
    registry.check()
    refresh()
  end
  return items
end

function M.setup()
  items = {}
  refreshed_at = nil
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("sidekick-ultra-status", { clear = true }),
    pattern = { registry.ATTACH, registry.DETACH },
    callback = refresh,
  })
end

return M
