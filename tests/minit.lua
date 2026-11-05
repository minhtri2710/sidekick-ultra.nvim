-- Test entry point: nvim --headless -u NONE -l tests/minit.lua (run through scripts/test).
local root = vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))))
local stubs = assert(vim.uv.fs_realpath(root .. "/tests/bin"))

for _, name in ipairs({ "herdr", "rex" }) do
  local found = vim.fn.exepath(name)
  local real = found ~= "" and vim.uv.fs_realpath(found) or nil
  if real ~= stubs .. "/" .. name then
    vim.uv.fs_write(2, ("minit: %s resolves to %q, not the stub in tests/bin; refusing to run\n"):format(name, found))
    vim.cmd("cquit 2")
  end
end

vim.opt.runtimepath:prepend({ root, root .. "/.tests/deps/mini.test" })
package.path = root .. "/?.lua;" .. package.path

local MiniTest = require("mini.test")
MiniTest.setup({
  collect = {
    find_files = function()
      -- SKU_SPEC=<substring> narrows the run to matching spec paths while developing.
      local only = vim.env.SKU_SPEC
      return vim.tbl_filter(function(file)
        return not only or file:find(only, 1, true) ~= nil
      end, vim.fn.globpath(root .. "/tests", "**/*_spec.lua", true, true))
    end,
  },
})
MiniTest.run()

-- The reporter quits with the failure status once every case has run.
vim.wait(290000, function()
  return not MiniTest.is_executing()
end, 50)
vim.cmd("cquit 1")
