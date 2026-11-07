local actions = require("sidekick-ultra.actions")
local errors = require("sidekick-ultra.errors")
local fake = require("tests.helpers.fake")
local notify = require("tests.helpers.notify")
local registry = require("sidekick-ultra.registry")
local ui = require("tests.helpers.ui")

local expect = MiniTest.expect

local ESC_I = "\27[I"

describe("actions", function()
  local cap, pick, backend, orig_sleep, orig_cwd, tmp

  ---Register `backend` with one session per `tools` entry and attach them all.
  ---@param tools string[]
  ---@param opts? table backend options
  local function attached(tools, opts)
    local sessions = {}
    for _, tool in ipairs(tools) do
      table.insert(sessions, fake.session("herdr", tool))
    end
    backend = fake.backend("herdr", vim.tbl_extend("force", { sessions = sessions }, opts or {}))
    registry.register(backend)
    for _, session in ipairs(registry.discover()) do
      registry.attach(session)
    end
    backend.calls = {}
  end

  local function scratch(lines)
    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "" })
    return buf
  end

  local function methods()
    return vim.tbl_map(function(call)
      return call[1]
    end, backend.calls)
  end

  before_each(function()
    fake.reset({
      claude = { cmd = fake.INSTALLED },
      qwen = { cmd = fake.INSTALLED, mux_focus = true },
      codex = { cmd = fake.INSTALLED },
      gemini = { cmd = fake.INSTALLED, location = "escaped" },
    })
    cap = notify.capture()
    pick = ui.capture()
    orig_sleep = vim.uv.sleep
    orig_cwd = vim.fn.getcwd()
    tmp = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(tmp, "p")
    scratch()
  end)
  after_each(function()
    vim.uv.sleep = orig_sleep
    cap.restore()
    pick.restore()
    registry.reset()
    vim.cmd("silent! %bwipeout!")
    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    vim.cmd("silent! normal! \27")
  end)

  describe("send", function()
    it("delivers the text followed by LF to the attached session, without submit or focus", function()
      attached({ "claude" })
      actions.send({ msg = "hello" })
      expect.equality(backend.calls, { { "send", "herdr:claude1", "hello\n" } })
      expect.equality(cap.calls, {})
    end)

    it("submits, then focuses, when asked", function()
      attached({ "claude" })
      actions.send({ msg = "hello", submit = true, focus = true })
      expect.equality(methods(), { "send", "submit", "focus" })
    end)

    it("sends a focus-in, waits 50 ms, then the text for a mux_focus tool", function()
      attached({ "qwen" })
      vim.uv.sleep = function(ms)
        table.insert(backend.calls, { "sleep", ms })
      end
      actions.send({ msg = "hi", submit = true })
      expect.equality(backend.calls, {
        { "send", "herdr:qwen1", ESC_I },
        { "sleep", 50 },
        { "send", "herdr:qwen1", "hi\n" },
        { "submit", "herdr:qwen1" },
      })
    end)

    for _, id in ipairs({ "session_blocked", "status_unreadable" }) do
      it("notifies " .. id .. " and sends nothing else when the backend refuses", function()
        attached({ "claude" }, { fail = { send = errors.new(id, "x") } })
        actions.send({ msg = "hi", submit = true, focus = true })
        expect.equality(cap.ids(), { id })
        expect.equality(backend.delivered, {})
        expect.equality(methods(), { "send" })
      end)

      it("refuses the focus-in itself with " .. id .. ": no text, no submit, no focus", function()
        attached({ "qwen" }, { fail = { send = errors.new(id, "x") } })
        vim.uv.sleep = function()
          error("must not wait")
        end
        actions.send({ msg = "hi", submit = true, focus = true })
        expect.equality(cap.ids(), { id })
        expect.equality(backend.delivered, {})
        expect.equality(methods(), { "send" })
      end)
    end

    it("stops after the text when the backend refuses it, without submit or focus", function()
      attached({ "qwen" }, {
        fail = {
          send = function(n)
            return n == 2 and errors.new("session_blocked", "x") or nil
          end,
        },
      })
      vim.uv.sleep = function() end
      actions.send({ msg = "hi", submit = true, focus = true })
      expect.equality(backend.delivered, { ESC_I })
      expect.equality(cap.ids(), { "session_blocked" })
      expect.equality(methods(), { "send", "send" })
    end)

    it("does not focus when submit is refused", function()
      attached({ "claude" }, { fail = { submit = errors.new("backend_error", "x") } })
      actions.send({ msg = "hi", submit = true, focus = true })
      expect.equality(cap.ids(), { "backend_error" })
      expect.equality(methods(), { "send", "submit" })
    end)

    it("fails with render_failed and sends nothing, starts nothing", function()
      attached({ "claude" })
      actions.send({ msg = "see {function}" })
      expect.equality(cap.ids(), { "render_failed" })
      expect.equality(backend.calls, {})
    end)

    it("warns nothing_to_send for an empty render", function()
      attached({ "claude" })
      actions.send({})
      expect.equality(cap.ids(), { "nothing_to_send" })
      expect.equality(backend.calls, {})
    end)

    it("sends just a newline when the whole render is one newline", function()
      attached({ "claude" })
      actions.send({ msg = "\n" })
      expect.equality(backend.delivered, { "\n" })
    end)

    it("refuses with not_in_mux when no session is attached and no backend is inside", function()
      backend = fake.backend("herdr", { is_inside = false })
      registry.register(backend)
      actions.send({ msg = "hi", name = "claude" })
      expect.equality(cap.ids(), { "not_in_mux" })
      expect.equality({ #backend.of("start"), #backend.of("send") }, { 0, 0 })
    end)

    it("starts a not-started tool inside the mux, attaches it, then sends", function()
      backend = fake.backend("herdr", { is_inside = true })
      registry.register(backend)
      actions.send({ msg = "hi", name = "codex" })
      expect.equality(
        vim.tbl_map(function(call)
          return call[1]
        end, backend.of("start")),
        { "start" }
      )
      expect.equality(backend.delivered, { "hi\n" })
      expect.equality(registry.attached()[1].id, "herdr:codexnew1")
    end)

    describe("start focus", function()
      local function started_backend(opts)
        backend = fake.backend("herdr", vim.tbl_extend("force", { is_inside = true }, opts or {}))
        registry.register(backend)
      end

      it("focuses the new session after the start and before the text", function()
        started_backend()
        actions.send({ msg = "hi", name = "codex" })
        expect.equality(methods(), { "list", "start", "focus", "send" })
        expect.equality(backend.of("focus"), { { "focus", "herdr:codexnew1" } })
      end)

      it("focuses at start and again after delivery with focus = true", function()
        started_backend()
        actions.send({ msg = "hi", name = "codex", focus = true })
        expect.equality(methods(), { "list", "start", "focus", "send", "focus" })
      end)

      it("does not focus at start with focus = false, and still delivers", function()
        started_backend()
        actions.send({ msg = "hi", name = "codex", focus = false })
        expect.equality(methods(), { "list", "start", "send" })
        expect.equality(backend.delivered, { "hi\n" })
      end)

      it("notifies a refused focus, keeps the session attached and still delivers", function()
        started_backend({ fail = { focus = errors.new("backend_error", "x") } })
        actions.send({ msg = "hi", name = "codex" })
        local failures = vim.tbl_filter(function(call)
          return call.id
        end, cap.calls)
        expect.equality({ #failures, failures[1].id }, { 1, "backend_error" })
        expect.equality(registry.attached()[1].id, "herdr:codexnew1")
        expect.equality(backend.delivered, { "hi\n" })
      end)
    end)

    it("picks among several attached sessions", function()
      attached({ "claude", "codex" })
      pick.choose = function(items)
        return items[2]
      end
      actions.send({ msg = "hi" })
      expect.equality(backend.calls, { { "send", "herdr:codex1", "hi\n" } })
    end)

    it("sends the selection in visual mode when there is no msg or prompt, and leaves visual mode", function()
      attached({ "claude" })
      scratch({ "alpha", "beta", "gamma" })
      vim.cmd("normal! ggVj")
      expect.equality(vim.fn.mode(), "V")
      actions.send({})
      expect.equality(backend.delivered, { "alpha\nbeta\n" })
      expect.equality(vim.fn.mode(), "n")
    end)

    it("sends the selection of a ranged :SidekickUltra send, and leaves visual mode", function()
      attached({ "claude" })
      scratch({ "alpha", "beta", "gamma" })
      vim.cmd("normal! ggVj\27")
      vim.cmd("'<,'>SidekickUltra send")
      expect.equality(backend.delivered, { "alpha\nbeta\n" })
      expect.equality(vim.fn.mode(), "n")
    end)

    it("writes locations in the target tool's style", function()
      local file = tmp .. "/my file.lua"
      vim.fn.writefile({ "x" }, file)
      vim.cmd("cd " .. vim.fn.fnameescape(tmp))
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      attached({ "claude" })
      actions.send({ msg = "{file}" })
      expect.equality(backend.delivered, { '@"my file.lua"\n' })

      backend.delivered = {}
      registry.reset()
      attached({ "gemini" })
      actions.send({ msg = "{file}" })
      expect.equality(backend.delivered, { "@my\\ file.lua\n" })

      backend.delivered = {}
      registry.reset()
      attached({ "codex" })
      actions.send({ msg = "{file}" })
      expect.equality(backend.delivered, { "@my file.lua\n" })
    end)

    it("evaluates a user context function once per send", function()
      local count = 0
      fake.reset({ claude = { cmd = fake.INSTALLED } }, {
        context = {
          counted = function()
            count = count + 1
            return "c"
          end,
        },
      })
      local file = tmp .. "/my file.lua"
      vim.fn.writefile({ "x" }, file)
      vim.cmd("cd " .. vim.fn.fnameescape(tmp))
      vim.cmd("edit " .. vim.fn.fnameescape(file))

      attached({ "claude" })
      actions.send({ msg = "{counted} {file}" })
      expect.equality(count, 1)
      expect.equality(backend.delivered, { 'c @"my file.lua"\n' })
    end)
  end)

  describe("prompt", function()
    local function names(items)
      return vim.tbl_map(function(item)
        return item.name
      end, items)
    end

    ---Choose the item called `name` in a prompt picker.
    local function choose(name)
      return function(items)
        return vim.tbl_filter(function(item)
          return item.name == name
        end, items)[1]
      end
    end

    ---The preview text of the item called `name` in the last picker.
    local function preview(name)
      local items = pick.selects[#pick.selects].items
      return vim.tbl_filter(function(item)
        return item.name == name
      end, items)[1].preview.text
    end

    local function file_buffer()
      local file = tmp .. "/my file.lua"
      vim.fn.writefile({ "x" }, file)
      vim.cmd("cd " .. vim.fn.fnameescape(tmp))
      vim.cmd("edit " .. vim.fn.fnameescape(file))
    end

    it("lists the renderable prompts sorted and sends the choice", function()
      attached({ "codex" })
      pick.choose = choose("changes")
      actions.prompt({})
      local listed = names(pick.selects[1].items)
      expect.equality(listed, vim.fn.sort(vim.deepcopy(listed)))
      expect.equality(vim.tbl_contains(listed, "changes"), true)
      -- A scratch buffer has no file, so every prompt that needs {function}, {this}-selection, ... is left out.
      expect.equality(vim.tbl_contains(listed, "explain"), false)
      expect.equality(vim.tbl_contains(listed, "diagnostics"), false)
      expect.equality(backend.delivered, { "Can you review my changes?\n" })
    end)

    it("lists every default prompt for a file buffer except the ones with empty sources", function()
      local file = tmp .. "/a.lua"
      vim.fn.writefile({ "x" }, file)
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      attached({ "codex" })
      pick.choose = function()
        return nil
      end
      actions.prompt({})
      local listed = names(pick.selects[1].items)
      for _, name in ipairs({
        "changes",
        "explain",
        "fix",
        "optimize",
        "review",
        "tests",
        "file",
        "line",
        "position",
        "buffers",
      }) do
        expect.equality(vim.tbl_contains(listed, name), true)
      end
      expect.equality(vim.tbl_contains(listed, "function"), false)
      expect.equality(backend.calls, {})
      expect.equality(cap.calls, {})
    end)

    it("previews the exact text of each prompt", function()
      attached({ "codex" })
      pick.choose = function() end
      actions.prompt({})
      expect.equality(preview("changes"), "Can you review my changes?")
    end)

    for _, case in ipairs({
      { tool = "codex", text = "@my file.lua" },
      { tool = "claude", text = '@"my file.lua"' },
      { tool = "gemini", text = "@my\\ file.lua" },
    }) do
      it("previews exactly the text sent to " .. case.tool .. " (its location style)", function()
        file_buffer()
        attached({ case.tool })
        pick.choose = choose("file")
        actions.prompt({})
        expect.equality(preview("file"), case.text)
        expect.equality(backend.delivered, { case.text .. "\n" })
      end)
    end

    it("previews the style of the tool picked first, not of another attachable tool", function()
      file_buffer()
      backend = fake.backend("herdr", {
        sessions = { fake.session("herdr", "claude"), fake.session("herdr", "gemini") },
      })
      registry.register(backend)
      pick.choose = function(items)
        if items[1].preview == nil then
          return vim.tbl_filter(function(state)
            return state.name == "gemini"
          end, items)[1]
        end
        return choose("file")(items)
      end
      actions.prompt({})
      expect.equality(preview("file"), "@my\\ file.lua")
      expect.equality(backend.delivered, { "@my\\ file.lua\n" })
    end)

    it("picks the target before the prompt picker when nothing is attached", function()
      backend = fake.backend("herdr", {
        sessions = { fake.session("herdr", "claude"), fake.session("herdr", "codex") },
      })
      registry.register(backend)
      pick.choose = function(items)
        if items[1].preview then
          return choose("changes")(items)
        end
        return vim.tbl_filter(function(state)
          return state.name == "codex" and state.started
        end, items)[1]
      end
      actions.prompt({})
      expect.equality(
        vim.tbl_map(function(select)
          return select.opts.prompt
        end, pick.selects),
        { "sidekick-ultra", "sidekick-ultra prompt" }
      )
      expect.equality(backend.of("send"), { { "send", "herdr:codex1", "Can you review my changes?\n" } })
    end)

    describe("a tool it starts", function()
      local function started_backend()
        backend = fake.backend("herdr", { is_inside = true })
        registry.register(backend)
        pick.choose = function(items)
          table.insert(backend.calls, { "picker" })
          return choose("changes")(items)
        end
      end

      it("is started before the prompt picker, focused only after the delivery", function()
        started_backend()
        actions.prompt({ name = "codex" })
        expect.equality(methods(), { "list", "start", "picker", "send", "focus" })
        expect.equality(
          vim.tbl_map(function(select)
            return select.opts.prompt
          end, pick.selects),
          { "sidekick-ultra prompt" }
        )
        expect.equality(backend.of("send"), { { "send", "herdr:codexnew1", "Can you review my changes?\n" } })
        expect.equality(backend.of("focus"), { { "focus", "herdr:codexnew1" } })
      end)

      it("is focused after a cancel, nothing is sent, and it stays attached", function()
        started_backend()
        pick.choose = function()
          table.insert(backend.calls, { "picker" })
        end
        actions.prompt({ name = "codex" })
        expect.equality(methods(), { "list", "start", "picker", "focus" })
        expect.equality(registry.attached()[1].id, "herdr:codexnew1")
      end)

      it("is never focused with focus = false, by a choice or a cancel", function()
        started_backend()
        actions.prompt({ name = "codex", focus = false })
        expect.equality(methods(), { "list", "start", "picker", "send" })
        registry.detach("herdr:codexnew1")
        backend.calls = {}
        pick.choose = function() end
        actions.prompt({ name = "codex", focus = false })
        expect.equality(methods(), { "list", "start" })
      end)

      it("is focused exactly once with focus = true, by a choice or a cancel", function()
        started_backend()
        actions.prompt({ name = "codex", focus = true })
        expect.equality(methods(), { "list", "start", "picker", "send", "focus" })
        registry.detach("herdr:codexnew1")
        backend.calls = {}
        pick.choose = function() end
        actions.prompt({ name = "codex", focus = true })
        expect.equality(methods(), { "list", "start", "focus" })
      end)

      for _, case in ipairs({
        {
          "the text",
          "codex",
          { send = errors.new("session_blocked", "x") },
          { submit = true },
          { "list", "start", "picker", "send", "focus" },
        },
        {
          "the focus-in",
          "qwen",
          { send = errors.new("status_unreadable", "x") },
          {},
          { "list", "start", "picker", "send", "focus" },
        },
        {
          "the submit",
          "codex",
          { submit = errors.new("backend_error", "x") },
          { submit = true },
          { "list", "start", "picker", "send", "submit", "focus" },
        },
      }) do
        local step, name, fail, extra, order = unpack(case)
        for _, focus in ipairs({ true, "unset" }) do
          it(
            ("is focused exactly once when the backend refuses %s, focus = %s"):format(step, tostring(focus)),
            function()
              backend = fake.backend("herdr", { is_inside = true, fail = fail })
              registry.register(backend)
              pick.choose = function(items)
                table.insert(backend.calls, { "picker" })
                return choose("changes")(items)
              end
              vim.uv.sleep = function() end
              local opts = vim.tbl_extend("force", { name = name }, extra)
              opts.focus = focus ~= "unset" or nil
              actions.prompt(opts)
              expect.equality(methods(), order)
              expect.equality(#backend.of("focus"), 1)
            end
          )
        end
      end
    end)

    it("does not focus an attached session unless focus = true", function()
      attached({ "claude" })
      pick.choose = choose("changes")
      actions.prompt({})
      expect.equality(methods(), { "send" })
    end)

    it("notifies a msg that does not render and opens no picker, starts nothing", function()
      backend = fake.backend("herdr", { is_inside = true })
      registry.register(backend)
      actions.prompt({ name = "codex", msg = "see {function}" })
      expect.equality(cap.ids(), { "render_failed" })
      expect.equality(#pick.selects, 0)
      expect.equality(backend.calls, {})
    end)

    it("opens an empty picker without resolving a target when no prompt renders", function()
      local none = {}
      for name in pairs(require("sidekick-ultra.context.render").default_prompts) do
        none[name] = false
      end
      fake.reset({ claude = { cmd = fake.INSTALLED } }, { prompts = none })
      backend = fake.backend("herdr", { is_inside = true })
      registry.register(backend)
      actions.prompt({ name = "claude" })
      expect.equality(#pick.selects, 1)
      expect.equality(pick.selects[1].items, {})
      expect.equality(backend.calls, {})
    end)

    it("opens no target picker when one session is attached", function()
      attached({ "claude" })
      pick.choose = choose("changes")
      actions.prompt({})
      expect.equality(#pick.selects, 1)
      expect.equality(pick.selects[1].opts.prompt, "sidekick-ultra prompt")
    end)

    it("delivers to the session picked first when several are attached, with no second pick", function()
      file_buffer()
      attached({ "claude", "gemini" })
      pick.choose = function(items)
        if items[1].preview == nil then
          return items[2]
        end
        return choose("file")(items)
      end
      actions.prompt({})
      expect.equality(#pick.selects, 2)
      expect.equality(backend.calls, { { "send", "herdr:gemini1", "@my\\ file.lua\n" } })
    end)

    it("applies submit and focus to the delivery", function()
      attached({ "claude" })
      pick.choose = choose("changes")
      actions.prompt({ submit = true, focus = true })
      expect.equality(methods(), { "send", "submit", "focus" })
    end)

    it("warns nothing_to_send for a prompt that renders empty, and sends nothing", function()
      fake.reset({ claude = { cmd = fake.INSTALLED } }, {
        prompts = {
          blank = function()
            return ""
          end,
        },
      })
      attached({ "claude" })
      pick.choose = choose("blank")
      actions.prompt({})
      expect.equality(cap.ids(), { "nothing_to_send" })
      expect.equality(backend.calls, {})
    end)

    it("uses the selection of a ranged :SidekickUltra prompt, and leaves visual mode", function()
      attached({ "claude" })
      scratch({ "alpha", "beta", "gamma" })
      vim.cmd("normal! ggVj\27")
      pick.choose = choose("selection")
      vim.cmd("'<,'>SidekickUltra prompt")
      expect.equality(backend.delivered, { "alpha\nbeta\n" })
      expect.equality(vim.fn.mode(), "n")
    end)

    it("leaves visual mode before it writes", function()
      attached({ "claude" })
      scratch({ "alpha", "beta", "gamma" })
      vim.cmd("normal! ggVj")
      expect.equality(vim.fn.mode(), "V")
      pick.choose = choose("selection")
      actions.prompt({})
      expect.equality(backend.delivered, { "alpha\nbeta\n" })
      expect.equality(vim.fn.mode(), "n")
    end)
  end)

  describe("select", function()
    it("attaches the chosen session and shows one message", function()
      backend = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
      registry.register(backend)
      pick.choose = function(items)
        return vim.tbl_filter(function(s)
          return s.started
        end, items)[1]
      end
      actions.select({})
      expect.equality(registry.attached()[1].id, "herdr:claude1")
      expect.equality(#cap.calls, 1)
      expect.equality(methods(), { "list" })
    end)

    it("focuses the chosen session with focus=true", function()
      backend = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
      registry.register(backend)
      pick.choose = function(items)
        return vim.tbl_filter(function(s)
          return s.started
        end, items)[1]
      end
      actions.select({ focus = true })
      expect.equality(backend.of("focus"), { { "focus", "herdr:claude1" } })
    end)

    describe("start focus", function()
      local function codex_row(items)
        return vim.tbl_filter(function(s)
          return s.name == "codex"
        end, items)[1]
      end
      local function started_backend()
        backend = fake.backend("herdr", { is_inside = true })
        registry.register(backend)
        pick.choose = codex_row
      end

      it("focuses a tool it starts exactly once by default", function()
        started_backend()
        actions.select({})
        expect.equality(backend.of("focus"), { { "focus", "herdr:codexnew1" } })
      end)

      it("focuses a tool it starts exactly once with focus = true", function()
        started_backend()
        actions.select({ focus = true })
        expect.equality(backend.of("focus"), { { "focus", "herdr:codexnew1" } })
      end)

      it("does not focus a tool it starts with focus = false, and attaches it", function()
        started_backend()
        actions.select({ focus = false })
        expect.equality(backend.of("focus"), {})
        expect.equality(registry.attached()[1].id, "herdr:codexnew1")
      end)

      it("receives focus = false from :SidekickUltra select focus=false", function()
        started_backend()
        require("sidekick-ultra.command").run("select focus=false")
        expect.equality({ #backend.of("start"), #backend.of("focus") }, { 1, 0 })
      end)

      it("does not focus an already running session with focus = false", function()
        backend = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
        registry.register(backend)
        pick.choose = function(items)
          return vim.tbl_filter(function(s)
            return s.started
          end, items)[1]
        end
        actions.select({ focus = false })
        expect.equality({ #registry.attached(), backend.of("focus") }, { 1, {} })
      end)

      it("does not focus an already running session by default", function()
        backend = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
        registry.register(backend)
        pick.choose = function(items)
          return vim.tbl_filter(function(s)
            return s.started
          end, items)[1]
        end
        actions.select({})
        expect.equality(backend.of("focus"), {})
      end)
    end)

    it("applies the name filter to the picker", function()
      backend = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
      registry.register(backend)
      pick.choose = function() end
      actions.select({ name = "codex" })
      expect.equality(
        vim.tbl_map(function(s)
          return s.name
        end, pick.selects[1].items),
        { "codex" }
      )
    end)
  end)

  describe("focus", function()
    it("focuses every target session through its backend", function()
      attached({ "claude" })
      actions.focus({})
      expect.equality(backend.calls, { { "focus", "herdr:claude1" } })
    end)

    it("attaches through the picker when nothing is attached", function()
      backend = fake.backend("herdr", { sessions = { fake.session("herdr", "claude") } })
      registry.register(backend)
      actions.focus({ name = "claude" })
      expect.equality(backend.of("focus"), { { "focus", "herdr:claude1" } })
      expect.equality(#registry.attached(), 1)
    end)

    it("focuses a tool it starts exactly once", function()
      backend = fake.backend("herdr", { is_inside = true })
      registry.register(backend)
      actions.focus({ name = "codex" })
      expect.equality(backend.of("focus"), { { "focus", "herdr:codexnew1" } })
      expect.equality(registry.attached()[1].id, "herdr:codexnew1")
    end)

    it("focuses even with focus = false: that key only governs the other actions", function()
      attached({ "claude" })
      actions.focus({ focus = false })
      expect.equality(backend.calls, { { "focus", "herdr:claude1" } })
    end)

    it("reports a failing focus", function()
      attached({ "claude" }, { fail = { focus = errors.new("backend_error", "x") } })
      actions.focus({})
      expect.equality(cap.ids(), { "backend_error" })
    end)
  end)

  describe("close", function()
    it("detaches the attached session with one message and does not touch the backend", function()
      attached({ "claude" })
      actions.close({})
      expect.equality(registry.attached(), {})
      expect.equality(#cap.calls, 1)
      expect.equality(cap.calls[1].level, vim.log.levels.INFO)
      expect.equality(backend.calls, {})
    end)

    it("picks one of several attached sessions unless all=true", function()
      attached({ "claude", "codex" })
      pick.choose = function(items)
        return items[2]
      end
      actions.close({})
      expect.equality(
        vim.tbl_map(function(s)
          return s.id
        end, registry.attached()),
        { "herdr:claude1" }
      )
      actions.close({ all = true })
      expect.equality(registry.attached(), {})
    end)

    it("honors the name filter", function()
      attached({ "claude", "codex" })
      actions.close({ name = "codex" })
      expect.equality(registry.attached()[1].id, "herdr:claude1")
    end)

    it("warns no_match when nothing is attached", function()
      attached({})
      actions.close({})
      expect.equality(cap.ids(), { "no_match" })
    end)
  end)

  describe("render", function()
    it("leaves visual mode after capturing the selection", function()
      scratch({ "alpha", "beta", "gamma" })
      vim.cmd("normal! ggVj")
      expect.equality(actions.render({ msg = "{selection}" }), "alpha\nbeta")
      expect.equality(vim.fn.mode(), "n")
    end)

    it("returns the rendered text without sending", function()
      attached({ "claude" })
      local text, err = actions.render({ msg = "{file|line}" })
      expect.equality({ text, err.id, err.names }, { nil, "render_failed", { "file|line" } })
      expect.equality(cap.ids(), { "render_failed" })
      expect.equality(actions.render({ msg = "plain", prompt = "changes" }), "plain\nCan you review my changes?")
      expect.equality(backend.calls, {})
    end)
  end)
end)
