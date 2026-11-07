---Replace vim.ui.select and vim.ui.open. `choose(items)` returns the item to pick (nil cancels).
local M = {}

function M.capture(choose)
  local orig_select, orig_open = vim.ui.select, vim.ui.open
  local cap = { selects = {}, opened = {} }
  cap.choose = choose or function(items)
    return items[1]
  end
  vim.ui.select = function(items, opts, on_choice)
    table.insert(cap.selects, { items = items, opts = opts })
    on_choice(cap.choose(items))
  end
  vim.ui.open = function(url)
    table.insert(cap.opened, url)
    return {}
  end
  function cap.restore()
    vim.ui.select, vim.ui.open = orig_select, orig_open
  end
  return cap
end

return M
