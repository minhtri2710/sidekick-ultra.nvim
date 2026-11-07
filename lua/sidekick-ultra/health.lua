---`:checkhealth sidekick-ultra`
local backends = require("sidekick-ultra.backends")
local config = require("sidekick-ultra.config")
local exec = require("sidekick-ultra.exec")
local registry = require("sidekick-ultra.registry")
local sources = require("sidekick-ultra.context.sources")
local tools = require("sidekick-ultra.tools")

local M = {}

local NVIM_FLOOR = "0.11.2"

---Report the version `<bin> <flag>` prints, and warn when it is older than the backend's minimum.
---@param name string
---@param bin string
---@param version { flag: string, min?: integer[] }
local function report_version(name, bin, version)
  local health = vim.health
  local min = version.min
  local res, err = exec.run({ bin, version.flag })
  if not res then
    health.warn(("%s: cannot read the version: %s"):format(name, err.msg))
  elseif res.code ~= 0 then
    health.warn(("%s: the version command exited with %d"):format(name, res.code))
  else
    -- The tools print their own name first ("tmux 3.8"); the row already starts with it.
    local line = vim.trim(vim.split(res.stdout, "\n", { plain = true })[1])
    health.info(("%s: version %s"):format(name, (line:gsub("^" .. name .. "%s+", ""))))
    -- "3.8", "3.7a" and "next-3.9" all hold major.minor; a line without one (a "master" build) is not judged.
    local major, minor = line:match("(%d+)%.(%d+)")
    if min and major and (tonumber(major) < min[1] or (tonumber(major) == min[1] and tonumber(minor) < min[2])) then
      health.warn(
        ("%s: %s is older than %d.%d, which `send` needs"):format(name, line, min[1], min[2]),
        { "Upgrade " .. name .. " to " .. ("%d.%d"):format(min[1], min[2]) .. " or newer" }
      )
    end
  end
end

---@param info sidekick_ultra.BackendInfo
---@param cfg sidekick_ultra.Config
local function report_backend(info, cfg)
  local health = vim.health
  local name, own = info.name, cfg[info.name]
  if not own.enabled then
    health.info(name .. ": disabled")
    return
  end
  local loaded, mod = pcall(require, "sidekick-ultra.backends." .. name)
  if not loaded then
    health.error(name .. ": backend module cannot be loaded: " .. tostring(mod))
    return
  end
  local ok, path, source = mod.available()
  if ok then
    health.ok(("%s: %s%s"):format(name, path or "available", source and (" (from " .. source .. ")") or ""))
  else
    local binary_key
    for key, option in pairs(info.options) do
      if option.binary and own[key] then
        binary_key = key
      end
    end
    if binary_key then
      health.error(("%s: %s.%s = %q is missing or not executable"):format(name, name, binary_key, own[binary_key]), {
        ("Fix or remove `%s.%s`: a configured binary has no fallback to PATH"):format(name, binary_key),
      })
    else
      health.error(
        name .. ": binary not found",
        { "Install " .. name .. " or disable it with `" .. name .. " = { enabled = false }`" }
      )
    end
  end
  if info.server_vars then
    local set = vim.tbl_filter(function(var)
      return vim.env[var] ~= nil
    end, info.server_vars)
    if #set > 0 then
      health.info(name .. ": server selected by " .. table.concat(set, ", "))
    else
      health.info(
        ("%s: neither %s is set; the default server is used"):format(name, table.concat(info.server_vars, " nor "))
      )
    end
  end
  health.info(("%s: nvim %s inside %s"):format(name, mod.inside() and "runs" or "does not run", name))
  local keys = vim.tbl_keys(info.options)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local report = info.options[key].report
    if report then
      health.info(name .. ": " .. (own[key] ~= nil and report.set or report.unset))
    end
  end
  if ok and info.version then
    report_version(name, path, info.version)
  end
end

function M.check()
  local health = vim.health
  local cfg = config.get()

  health.start("sidekick-ultra")
  if vim.fn.has("nvim-" .. NVIM_FLOOR) == 1 then
    health.ok("Neovim >= " .. NVIM_FLOOR)
  else
    health.error(("Neovim >= %s is required"):format(NVIM_FLOOR))
  end

  health.start("backends")
  for _, info in ipairs(backends.all) do
    report_backend(info, cfg)
  end
  local start, err = registry.start_backend()
  if start then
    health.ok(("nvim runs inside %s: start is available"):format(start.name))
  else
    health.info("start is unavailable: " .. err.msg)
  end

  health.start("context")
  local textobjects = sources.textobjects
  if #vim.api.nvim_get_runtime_file(("queries/*/%s.scm"):format(textobjects.query), false) > 0 then
    health.ok("nvim-treesitter-textobjects queries found")
  else
    local placeholders = vim.tbl_map(function(name)
      return "{" .. name .. "}"
    end, textobjects.sources)
    health.warn(
      ("nvim-treesitter-textobjects is missing; %s fail to render"):format(table.concat(placeholders, " and "))
    )
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
