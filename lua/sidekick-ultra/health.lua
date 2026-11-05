---`:checkhealth sidekick-ultra`
local config = require("sidekick-ultra.config")
local tools = require("sidekick-ultra.tools")

local M = {}

---Environment variable names herdr and rex use to find their server; only whether they are set is reported.
local HERDR_SERVER_VARS = { "HERDR_SOCKET_PATH", "HERDR_SESSION" }

---@param name string
---@param cfg sidekick_ultra.Config
---@return boolean inside
local function backend(name, cfg)
  local health = vim.health
  if not cfg[name].enabled then
    health.info(name .. ": disabled")
    return false
  end
  local loaded, mod = pcall(require, "sidekick-ultra.backends." .. name)
  if not loaded then
    health.error(name .. ": backend module cannot be loaded: " .. tostring(mod))
    return false
  end
  local ok, path, source = mod.available()
  if ok then
    health.ok(("%s: %s%s"):format(name, path or "available", source and (" (from " .. source .. ")") or ""))
  elseif name == "rex" and cfg.rex.bin then
    health.error(
      ("rex: rex.bin = %q is missing or not executable"):format(cfg.rex.bin),
      { "Fix or remove `rex.bin`: a configured binary has no fallback to PATH or the bundled rex" }
    )
  else
    health.error(
      name .. ": binary not found",
      { "Install " .. name .. " or disable it with `" .. name .. " = { enabled = false }`" }
    )
  end
  if name == "herdr" then
    local set = vim.tbl_filter(function(var)
      return vim.env[var] ~= nil
    end, HERDR_SERVER_VARS)
    if #set > 0 then
      health.info("herdr: server selected by " .. table.concat(set, ", "))
    else
      health.info("herdr: neither HERDR_SOCKET_PATH nor HERDR_SESSION is set; the default server is used")
    end
  elseif cfg.rex.server then
    health.info("rex: server is configured (rex.server)")
  else
    health.info("rex: rex.server is not configured")
  end
  return ok and mod.inside()
end

function M.check()
  local health = vim.health
  local cfg = config.get()

  health.start("sidekick-ultra")
  if vim.fn.has("nvim-0.11.2") == 1 then
    health.ok("Neovim >= 0.11.2")
  else
    health.error("Neovim >= 0.11.2 is required")
  end

  health.start("backends")
  local inside = {}
  for _, name in ipairs({ "herdr", "rex" }) do
    if backend(name, cfg) then
      table.insert(inside, name)
    end
  end
  if #inside > 0 then
    health.ok("nvim runs inside " .. table.concat(inside, " and ") .. ": start is available")
  else
    health.info("nvim does not run inside herdr or rex: start is unavailable")
  end

  health.start("context")
  if #vim.api.nvim_get_runtime_file("queries/*/textobjects.scm", false) > 0 then
    health.ok("nvim-treesitter-textobjects queries found")
  else
    health.warn("nvim-treesitter-textobjects is missing; {function} and {class} stay empty")
  end

  health.start("tools")
  for _, tool in ipairs(tools.list()) do
    if tools.installed(tool) then
      health.info(tool.name .. ": installed (" .. tool.cmd[1] .. ")")
    else
      health.info(tool.name .. ": missing (" .. tool.cmd[1] .. ")")
    end
  end
end

return M
