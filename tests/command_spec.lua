local actions = require("sidekick-ultra.actions")
local command = require("sidekick-ultra.command")
local fake = require("tests.helpers.fake")
local notify = require("tests.helpers.notify")

local expect = MiniTest.expect

describe("command", function()
  describe("parse", function()
    ---@return string? sub, table|string result
    local function parse(line)
      local sub, res = command.parse(line)
      if sub then
        return sub, res
      end
      return nil, res.id
    end

    it("returns incomplete_command for no subcommand", function()
      expect.equality({ parse("") }, { nil, "incomplete_command" })
      expect.equality({ parse("   ") }, { nil, "incomplete_command" })
    end)

    it("returns invalid_command for an unknown subcommand", function()
      expect.equality({ parse("bogus") }, { nil, "invalid_command" })
      expect.equality({ parse("bogus a=b") }, { nil, "invalid_command" })
    end)

    it("parses each subcommand with no arguments", function()
      for _, sub in ipairs({ "select", "send", "prompt", "focus", "close" }) do
        expect.equality({ parse(sub) }, { sub, {} })
      end
    end)

    it("parses key=value pairs, booleans and strings", function()
      local sub, opts = parse("send msg=hello submit=true focus=false name=claude")
      expect.equality(sub, "send")
      expect.equality(opts, { msg = "hello", submit = true, focus = false, name = "claude" })
    end)

    it('parses double-quoted values with \\" and \\\\ escapes', function()
      local _, opts = parse([[send msg="a \"b\" c\\d" submit=true]])
      expect.equality(opts, { msg = [[a "b" c\d]], submit = true })
    end)

    it("keeps other backslashes, equals signs and braces in values", function()
      local _, opts = parse([[send msg="x\ny = {file}"]])
      expect.equality(opts.msg, [[x\ny = {file}]])
    end)

    it("keeps true and false as text for string keys", function()
      local _, opts = parse("send name=true")
      expect.equality(opts.name, "true")
    end)

    it("never evaluates arguments", function()
      vim.g.sku_command_ran = false
      local _, opts = parse([[send msg="vim.g.x" name=lua]])
      expect.equality(opts, { msg = "vim.g.x", name = "lua" })
      local sub, err = parse([[send {msg = (function() vim.g.sku_command_ran = true end)()}]])
      expect.equality({ sub, err }, { nil, "invalid_args" })
      expect.equality(vim.g.sku_command_ran, false)
      vim.g.sku_command_ran = nil
    end)

    it("returns invalid_args for malformed arguments, naming them", function()
      for _, line in ipairs({
        "send msg",
        "send =x",
        "send msg=",
        "send nope=1",
        "send submit=maybe",
        'send submit="true"',
        'send msg="unterminated',
        'send msg="a"b',
        "close submit=true",
        "focus msg=x",
      }) do
        expect.equality({ parse(line) }, { nil, "invalid_args" })
      end
      local _, err = command.parse("send nope=1")
      expect.equality(err.arg, "nope")
    end)
  end)

  describe("run", function()
    local cap, calls, orig
    before_each(function()
      fake.reset()
      cap = notify.capture()
      calls = {}
      orig = {}
      for _, sub in ipairs({ "select", "send", "prompt", "focus", "close" }) do
        orig[sub] = actions[sub]
        actions[sub] = function(opts)
          table.insert(calls, { sub, opts, vim.fn.mode() })
        end
      end
    end)
    after_each(function()
      for sub, fn in pairs(orig) do
        actions[sub] = fn
      end
      cap.restore()
      vim.cmd("silent! %bwipeout!")
    end)

    it("dispatches to the action with the parsed options", function()
      command.run("send msg=hi submit=true")
      command.run("close all=true name=claude")
      expect.equality(calls[1], { "send", { msg = "hi", submit = true }, "n" })
      expect.equality(calls[2], { "close", { all = true, name = "claude" }, "n" })
    end)

    it("notifies the error id and runs nothing", function()
      command.run("")
      command.run("zzz")
      command.run("send q=1")
      expect.equality(cap.ids(), { "incomplete_command", "invalid_command", "invalid_args" })
      expect.equality(calls, {})
    end)

    it("restores the last visual selection first when called with a range", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c" })
      vim.cmd("normal! ggVj\27")
      expect.equality(vim.fn.mode(), "n")
      command.run("send msg=x", 2)
      expect.equality(calls[1][3], "V")
      vim.cmd("normal! \27")
      command.run("send msg=x", 0)
      expect.equality(calls[2][3], "n")
    end)

    it("enters visual mode only for the subcommands that read the selection, and leaves none in it", function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c" })
      for _, sub in ipairs({ "select", "focus", "close" }) do
        vim.cmd("normal! ggVj\27")
        vim.cmd("'<,'>SidekickUltra " .. sub)
        expect.equality({ sub, vim.fn.mode() }, { sub, "n" })
      end
    end)

    it("is registered as :SidekickUltra, accepting a range", function()
      expect.equality(vim.fn.exists(":SidekickUltra"), 2)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c" })
      vim.cmd("normal! ggVj\27")
      vim.cmd("'<,'>SidekickUltra send msg=hi")
      vim.cmd("SidekickUltra close all=true")
      expect.equality(calls[1], { "send", { msg = "hi" }, "V" })
      expect.equality(calls[2][1], "close")
    end)
  end)

  describe("complete", function()
    local function complete(cmdline)
      local lead = cmdline:match("(%S*)$")
      return command.complete(lead, cmdline, #cmdline)
    end

    it("completes subcommand names, filtered by the prefix", function()
      expect.equality(complete("SidekickUltra "), { "select", "send", "prompt", "focus", "close" })
      expect.equality(complete("SidekickUltra se"), { "select", "send" })
      expect.equality(complete("'<,'>SidekickUltra c"), { "close" })
    end)

    it("completes the argument keys of the chosen subcommand", function()
      expect.equality(complete("SidekickUltra close "), { "all=", "name=" })
      expect.equality(complete("SidekickUltra send "), { "focus=", "msg=", "name=", "prompt=", "submit=" })
      expect.equality(complete("SidekickUltra send s"), { "submit=" })
    end)

    it("leaves out keys that are already given", function()
      expect.equality(complete("SidekickUltra send msg=hi su"), { "submit=" })
      expect.equality(complete("SidekickUltra close all=true "), { "name=" })
    end)

    it("completes nothing for an unknown subcommand", function()
      expect.equality(complete("SidekickUltra nope "), {})
    end)
  end)
end)
