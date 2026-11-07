---@alias sidekick_ultra.ErrorId
---| "not_in_mux"
---| "session_blocked"
---| "status_unreadable"
---| "not_installed"
---| "no_match"
---| "nothing_to_send"
---| "unknown_context"
---| "unknown_prompt"
---| "render_failed"
---| "backend_error"
---| "duplicate_session"
---| "invalid_command"
---| "incomplete_command"
---| "invalid_args"

---A structured refusal or failure. Extra fields carry data for the caller, as `code` does.
---@class sidekick_ultra.Error
---@field id sidekick_ultra.ErrorId
---@field msg string human message; code classifies on `id` and the error's data, never on this
---@field code? integer exit code, for `backend_error` and `status_unreadable`

local M = {}

local TITLE = "sidekick-ultra"

local WARN = { no_match = true, nothing_to_send = true }

local ids = {
  "not_in_mux",
  "session_blocked",
  "status_unreadable",
  "not_installed",
  "no_match",
  "nothing_to_send",
  "unknown_context",
  "unknown_prompt",
  "render_failed",
  "backend_error",
  "duplicate_session",
  "invalid_command",
  "incomplete_command",
  "invalid_args",
}

---@type table<string, true>
M.ids = {}
for _, id in ipairs(ids) do
  M.ids[id] = true
end

---@param id sidekick_ultra.ErrorId
---@param msg string
---@param extra? table
---@return sidekick_ultra.Error
function M.new(id, msg, extra)
  assert(M.ids[id], "unknown error id: " .. tostring(id))
  return vim.tbl_extend("force", extra or {}, { id = id, msg = msg })
end

---@param level integer
---@param msg string
---@param id? string
function M.message(level, msg, id)
  vim.notify(msg, level, { title = TITLE, error_id = id })
end

---@param msg string
function M.info(msg)
  M.message(vim.log.levels.INFO, msg)
end

---Notify an error value. The id is passed to the notifier as `opts.error_id`.
---@param err sidekick_ultra.Error
function M.notify(err)
  M.message(WARN[err.id] and vim.log.levels.WARN or vim.log.levels.ERROR, err.msg, err.id)
end

return M
