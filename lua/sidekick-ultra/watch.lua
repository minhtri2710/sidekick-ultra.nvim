---Reload files the agent edits: while a session is attached, watch the directories of the open file buffers and run
---`checktime` when anything in them changes.
local config = require("sidekick-ultra.config")
local registry = require("sidekick-ultra.registry")

local M = {}

local DEBOUNCE_MS = 100
local GROUP = "sidekick-ultra-watch"
local SUBSCRIPTION = "sidekick-ultra-watch-sessions"
local EVENTS = { "BufAdd", "BufDelete", "BufWipeout", "BufReadPost" }

---@class sidekick_ultra.WatchState
---@field handles table<string, uv.uv_fs_event_t> watched directory -> handle
---@field timers uv.uv_timer_t[] debounce timers
---@field checktime? fun() debounced `checktime`, set while active
---@field active boolean
local state = { handles = {}, timers = {}, active = false }

---@param fn fun()
---@return fun()
local function debounce(fn)
  local timer = assert(vim.uv.new_timer())
  table.insert(state.timers, timer)
  return function()
    timer:stop()
    timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(fn))
  end
end

---Directories that hold a loaded, listed, normal file buffer whose file exists.
---@return table<string, true>
local function wanted()
  local dirs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.uv.fs_stat(name) then
        dirs[vim.fs.dirname(name)] = true
      end
    end
  end
  return dirs
end

local function sync()
  if not state.active then
    return
  end
  local dirs = wanted()
  for dir, handle in pairs(state.handles) do
    if not dirs[dir] then
      handle:close()
      state.handles[dir] = nil
    end
  end
  for dir in pairs(dirs) do
    if not state.handles[dir] then
      local handle = vim.uv.new_fs_event()
      if
        handle
        and handle:start(dir, {}, function()
            if state.active then
              state.checktime()
            end
          end)
          == 0
      then
        state.handles[dir] = handle
      elseif handle then
        handle:close()
      end
    end
  end
end

---@return boolean
function M.active()
  return state.active
end

---@return string[] directories currently watched, sorted
function M.dirs()
  local dirs = vim.tbl_keys(state.handles)
  table.sort(dirs)
  return dirs
end

local function start()
  if state.active then
    return
  end
  state.active = true
  state.checktime = debounce(function()
    vim.cmd("silent! checktime")
  end)
  local resync = debounce(sync)
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd(EVENTS, { group = group, callback = resync })
  sync()
end

---Stop watching. Safe to call when not watching.
function M.stop()
  if not state.active then
    return
  end
  state.active = false
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
  for _, timer in ipairs(state.timers) do
    timer:stop()
    timer:close()
  end
  for _, handle in pairs(state.handles) do
    handle:close()
  end
  state = { handles = {}, timers = {}, active = false }
end

---Start from a stopped state and follow the attach and detach events: watch while a session is attached and the
---`watch` option is on.
function M.setup()
  M.stop()
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup(SUBSCRIPTION, { clear = true }),
    pattern = { registry.ATTACH, registry.DETACH },
    callback = function()
      if #registry.attached() > 0 and config.get().watch then
        start()
      else
        M.stop()
      end
    end,
  })
end

return M
