local backend = require("sidekick-ultra.backend")
local backends = require("sidekick-ultra.backends")

local expect = MiniTest.expect

local DIR = vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))) .. "/../lua/sidekick-ultra/backends"

describe("backend table", function()
  it("lists exactly the backend modules, each of which satisfies the backend contract", function()
    local files = {}
    for file in vim.fs.dir(DIR) do
      if file ~= "init.lua" then
        table.insert(files, (file:gsub("%.lua$", "")))
      end
    end
    table.sort(files)
    local names = backends.names()
    table.sort(names)
    expect.equality(names, files)
    for _, name in ipairs(names) do
      local mod = require("sidekick-ultra.backends." .. name)
      expect.equality({ name, backend.check(mod) }, { name, true })
      expect.equality(mod.name, name)
    end
  end)
end)
