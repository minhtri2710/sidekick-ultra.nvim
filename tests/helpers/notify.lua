---Capture vim.notify calls: `local n = notify.capture()`; `n.calls` holds `{msg, level, id}`; `n.restore()` ends it.
local M = {}

function M.capture()
  local orig = vim.notify
  local cap = { calls = {} }
  vim.notify = function(msg, level, opts)
    table.insert(cap.calls, { msg = msg, level = level, id = opts and opts.error_id, title = opts and opts.title })
  end
  function cap.restore()
    vim.notify = orig
  end
  ---@return string[]
  function cap.ids()
    return vim.tbl_map(function(c)
      return c.id
    end, cap.calls)
  end
  return cap
end

return M
