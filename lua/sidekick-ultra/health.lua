---`:checkhealth sidekick-ultra`
local config = require("sidekick-ultra.config")
local exec = require("sidekick-ultra.exec")
local tools = require("sidekick-ultra.tools")

local M = {}

---Environment variable names herdr and rex use to find their server; only whether they are set is reported.
local HERDR_SERVER_VARS = { "HERDR_SOCKET_PATH", "HERDR_SESSION" }

---Report the version `<bin> -V` (tmux) or `<bin> --version` (zellij) prints.
---@param name string
---@param bin string
---@param min? integer[] {major, minor}: warn when the reported version is older
local function version(name, bin, min)
  local health = vim.health
  local res, err = exec.run({ bin, name == "tmux" and "-V" or "--version" }, { backend = name, cmd = "version" })
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
  elseif name == "rex" then
    if cfg.rex.server then
      health.info("rex: server is configured (rex.server)")
    else
      health.info("rex: rex.server is not configured")
    end
  else
    local inside = ok and mod.inside()
    health.info(("%s: nvim %s inside %s"):format(name, inside and "runs" or "does not run", name))
    if name == "tmux" then
      if cfg.tmux.socket then
        health.info("tmux: socket is configured (tmux.socket); every call uses -S")
      else
        health.info("tmux: tmux.socket is not configured; calls go to the server of $TMUX, else the default server")
      end
    end
    if ok then
      version(name, path, mod.MIN_VERSION)
    end
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
  for _, name in ipairs({ "herdr", "rex", "tmux", "zellij" }) do
    if backend(name, cfg) then
      table.insert(inside, name)
    end
  end
  if #inside > 0 then
    health.ok("nvim runs inside " .. table.concat(inside, " and ") .. ": start is available")
  else
    health.info("nvim does not run inside herdr, rex, tmux or zellij: start is unavailable")
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
