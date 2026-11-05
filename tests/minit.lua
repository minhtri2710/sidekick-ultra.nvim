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
  execute = { reporter = MiniTest.gen_reporter.stdout({ quit_on_finish = false }) },
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

-- Exit status: 1 when a case failed, 3 when a stub binary was reached (the stubs leave a marker in HOME), else 0.
-- If the run does not finish within the wait, that is a failure too.
local finished = vim.wait(290000, function()
  return not MiniTest.is_executing()
end, 50)
local failed = not finished
for _, case in ipairs(MiniTest.current.all_cases or {}) do
  failed = failed or (case.exec ~= nil and #case.exec.fails > 0)
end
if vim.uv.fs_stat(vim.env.HOME .. "/.sku-stub-reached") then
  vim.uv.fs_write(2, "minit: a stub herdr/rex was reached; a test ran a real binary\n")
  vim.cmd("cquit 3")
end
vim.cmd(failed and "cquit 1" or "0cquit")
