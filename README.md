# sidekick-ultra.nvim

Drive AI coding CLIs (claude, codex, gemini, and others) that run in herdr panes or rex blocks, from Neovim. Pick a running session, attach to it, and send it context from your editor: the current file, the cursor position, the visual selection, diagnostics, the quickfix list, or one of the built-in prompts.

This is a standalone rewrite, not a fork. It takes its workflow and vocabulary from [folke/sidekick.nvim](https://github.com/folke/sidekick.nvim), which was the inspiration and the behavior reference for the CLI feature, and shares no code with it. There is no Neovim `:terminal` window: the tools run in your multiplexer.

## Requirements

- Neovim >= 0.11.2
- herdr and/or rex, with Neovim running inside the multiplexer if you want to start tools from the editor
- the AI CLIs you want to use, on `PATH`
- optional: `nvim-treesitter-textobjects`, for the `{function}` and `{class}` placeholders

## Setup

```lua
{
  "minhtri2710/sidekick-ultra.nvim",
  cmd = "SidekickUltra",
  opts = {},
}
```

or call `require("sidekick-ultra").setup({})` yourself. `setup()` validates the options, registers every enabled backend whose binary is found, creates `:SidekickUltra` and defines the default keymaps. An invalid option raises an error that names its key path, for example `tools.claude.cmd`.

### Options

```lua
{
  -- Reload files the agent edits while a session is attached.
  watch = true,
  -- Default keymaps under `prefix` (see Keymaps); `false` defines none.
  keys = { prefix = "<leader>a" },
  herdr = { enabled = true },
  rex = {
    enabled = true,
    bin = nil,    -- path to the rex binary; default: rex on PATH, then the Rex Beta app bundle
    server = nil, -- passed to rex as -S <server>
  },
  -- Merged per tool over the built-ins; `false` removes a tool; a new name adds one (`cmd` required).
  tools = {
    claude = { env = { FOO = "bar" } },
    aider = false,
    mytool = { cmd = { "mytool", "--flag" }, is_proc = "\\<mytool\\>", location = "plain" },
  },
  -- Merged over the built-in prompts; `false` removes one. A prompt is a string,
  -- `{ msg = string }`, or a function of the context snapshot returning a string.
  prompts = {
    refactor = "Refactor {this} for readability",
  },
  -- Extra `{placeholders}`: a function of the snapshot returning a string, a list of strings, or nil.
  context = {
    branch = function(snap)
      return vim.trim(vim.fn.system({ "git", "-C", snap.cwd, "branch", "--show-current" }))
    end,
  },
}
```

Tool fields: `cmd` (non-empty list), `env`, `url`, `is_proc` (Vim regex or a function of `{pid, cmd}`; the default matches the command name as a word), `mux_focus` (send a focus-in event before input), `location` (`plain`, `claude` or `escaped`: how file locations are written in sent text).

Built-in tools: aider, amazon_q, claude, codex, copilot, crush, cursor, gemini, grok, opencode, pi, qwen.

## Keymaps

`setup()` defines these global maps under `keys.prefix` (default `<leader>a`). Each calls the Lua API. The prefix itself carries the description `+sidekick-ultra` for which-key style menus.

| Keys | Modes | Does |
|---|---|---|
| `<leader>as` | n | `select()`: pick a session or tool |
| `<leader>at` | n, x | `send({ msg = "{this}" })` |
| `<leader>af` | n | `send({ msg = "{file}" })` |
| `<leader>av` | x | `send({ msg = "{selection}" })` |
| `<leader>ap` | n, x | `prompt()`: pick a prompt |
| `<leader>ao` | n | `focus()` |
| `<leader>ad` | n | `close()`: detach (the tool keeps running) |

`keys = { prefix = "<leader>S" }` moves them all. `keys = false` defines none. A second `setup()` removes the maps the first one defined, and never a map you set yourself. `prefix` must be a non-empty string, and `keys` accepts no other key.

With lazy.nvim the keys exist before the plugin loads, even with only `cmd = "SidekickUltra"` and `opts = {}`:

```lua
{
  "minhtri2710/sidekick-ultra.nvim",
  cmd = "SidekickUltra",
  opts = {},
}
```

lazy.nvim reads the `lazy.lua` at the repository root when it installs or updates the plugin. It adds the same keys, from your merged `opts.keys`, as triggers without a right-hand side. Pressing one loads the plugin, `setup()` defines the real map, and lazy.nvim replays the key. `keys = false` adds no triggers.

## Commands

`:SidekickUltra <sub> [key=value ...]`. Values may be double-quoted, with `\"` and `\\` escapes. `true` and `false` are booleans for boolean keys. Arguments are parsed, never evaluated. With a range (`:'<,'>SidekickUltra send ...`) the last visual selection is restored first, so `{selection}` works.

| Subcommand | Keys | Does |
|---|---|---|
| `select` | `name`, `focus` | pick a session or tool, attach it; a tool without a session is started next to Neovim |
| `send` | `msg`, `prompt`, `name`, `submit`, `focus` | render the message or prompt and send it to the target session |
| `prompt` | `name`, `submit`, `focus` | pick a prompt and send it |
| `focus` | `name` | focus the target's pane or block |
| `close` | `name`, `all` | detach (the tool keeps running) |

The target is the attached session. With none attached, a picker opens over the matching sessions and tools. With several, you choose one (except `close all=true`).

The same actions exist in Lua: `require("sidekick-ultra").send({ msg = "{file}", submit = true })`, `.prompt()`, `.select()`, `.focus()`, `.close()`, and `.render()` (returns the text without sending). They take `name`, `filter` (`name`, `session`, `attached`, `started`, `installed`, `cwd`, `backend`), `submit`, `focus`, `msg`, `prompt`, and `all` for `close`.

## Context

A message is text with `{name}` placeholders. `{a|b}` uses the first alternative that yields something. If a placeholder yields nothing, nothing is sent and the error names it (`render_failed`).

| Placeholder | Yields |
|---|---|
| `{this}` | in a file buffer `{position}`; otherwise the word "this" followed by `{selection}` |
| `{position}` `{file}` `{line}` | `@path :L10:C5`, `@path`, `@path :L10` for the cursor or selection |
| `{selection}` | the selected text, de-indented |
| `{buffers}` | one `- @path` line per listed file buffer |
| `{diagnostics}` `{diagnostics_all}` | diagnostics of the buffer, or of all buffers |
| `{quickfix}` | the quickfix list |
| `{function}` `{class}` | the enclosing function or class (needs `nvim-treesitter-textobjects`) |

Built-in prompts: changes, diagnostics, diagnostics_all, document, explain, fix, optimize, review, tests, plus one per placeholder.

## Statusline

```lua
require("sidekick-ultra.status").cli()
-- { { id = "herdr:w1-1", tool = "claude", cwd = "...", backend = "herdr", state = "idle" }, ... }
```

One entry per attached session, with `state` set when the backend reports one. It never runs an external command. Events `User SidekickUltraAttach` and `User SidekickUltraDetach` carry `data = { id = ... }`.

## Safety

- `send` re-reads the session state first and refuses (`session_blocked`) when the agent is blocked on a prompt, and refuses (`status_unreadable`) when the state cannot be read.
- Starting a tool is allowed only when Neovim runs inside that multiplexer (`not_in_mux` otherwise). If it runs inside both, `TERM_PROGRAM` decides.
- Notifications carry a stable error id: `not_in_mux`, `session_blocked`, `status_unreadable`, `not_installed`, `no_match`, `nothing_to_send`, `unknown_context`, `unknown_prompt`, `render_failed`, `backend_error`, `duplicate_session`, `invalid_command`, `incomplete_command`, `invalid_args`.

## Health

`:checkhealth sidekick-ultra` reports the Neovim version, each backend (enabled, binary path and where it came from, server settings by variable name only), whether Neovim runs inside herdr or rex, whether the textobjects queries are available, and which tools are installed.

## Development

```sh
make check        # stylua --check, selene, and the test suite
make test-floor   # the suite under Neovim 0.11.2 (NVIM=/tmp/sku-nvim-0.11/nvim-macos-arm64/bin/nvim)
```

`scripts/test` clones mini.test at a pinned commit into `.tests/deps`, runs the specs in an isolated HOME with stub `herdr` and `rex` binaries first on `PATH` (a stub that is reached prints `stub reached` and exits 97), and bounds the run at 300 s. The backend contract is documented in `lua/sidekick-ultra/backend.lua`.

## License

MIT. See `LICENSE`.
