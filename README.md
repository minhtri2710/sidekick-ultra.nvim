# sidekick-ultra.nvim

Drive AI coding CLIs (claude, codex, gemini, and others) that run in herdr panes, rex blocks, tmux panes or zellij panes, from Neovim. Pick a running session, attach to it, and send it context from your editor: the current file, the cursor position, the visual selection, diagnostics, the quickfix list, or one of the built-in prompts.

This is a standalone rewrite, not a fork. It takes its workflow and vocabulary from [folke/sidekick.nvim](https://github.com/folke/sidekick.nvim), which was the inspiration and the behavior reference for the CLI feature, and shares no code with it. There is no Neovim `:terminal` window: the tools run in your multiplexer.

## Requirements

- Neovim >= 0.11.2
- at least one of herdr, rex, tmux or zellij, with Neovim running inside the multiplexer if you want to start tools from the editor
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
  tmux = {
    enabled = true,
    socket = nil, -- non-empty path; adds -S <socket> to every tmux call
  },
  zellij = { enabled = true },
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

## tmux and zellij

Both are backends like herdr and rex: they list the panes that run a configured tool, start a tool in a new pane beside Neovim's own, send text, press Enter and focus a pane. Each is enabled by default and registered when its binary is found; `tmux = { enabled = false }` or `zellij = { enabled = false }` turns one off.

What they do not have is an agent status. herdr and rex tell the plugin when an agent is blocked on a prompt; tmux and zellij do not. So on tmux and zellij `send` never refuses with `session_blocked` or `status_unreadable`: the text goes to the pane whatever it is doing.

**tmux** (checked against tmux 3.8)

- Neovim counts as inside tmux when `TMUX` and `TMUX_PANE` are set, and, if `tmux.socket` is set, when the server in `TMUX` is that socket (compared after normalizing and resolving the path); otherwise start is refused with `not_in_mux`. Starting a tool is allowed only when inside.
- Without `tmux.socket`, calls go to the server named by `TMUX`, or to tmux's default server when Neovim runs outside tmux. With `socket`, every call is `tmux -S <socket> ...`. Set it to reach a private server from an editor that runs outside tmux.
- Discovery lists every pane of the server, in all sessions, with one `list-panes -a` call, and skips dead panes. A pane counts when a process in its process tree (the pane's own process and everything below it) is a configured tool. Neovim reads the tree itself; no `ps` runs and no command line or environment is read. No running server means no sessions, not an error.
- A session id is `tmux:%N`, with the pane id tmux gives.
- Start splits to the right of Neovim's pane without focus, in Neovim's directory, with the tool's `env` as `-e K=V`.
- tmux 3.7 or newer is required: `send` pastes with `paste-buffer -S` (new in 3.7), which keeps control characters as the bytes they are. `:checkhealth` warns below 3.7.
- `send` pastes the text through a temporary tmux buffer with no Enter, and line feeds stay line feeds. `submit` sends Enter. Both first leave copy mode (or any other pane mode) if the pane is in one, since a pane in a mode takes keys and pastes for the mode instead of the program.
- `focus` selects the pane's window and the pane. When Neovim runs inside tmux and the pane is in another session, it also switches the client to it.

**zellij** (checked against zellij 0.45.1)

- Neovim counts as inside zellij when `ZELLIJ` and `ZELLIJ_PANE_ID` are set. Calls inside zellij go to the current session (`ZELLIJ_SESSION_NAME`). Outside zellij, discovery asks every session in turn. There is no zellij option besides `enabled`.
- zellij gives the plugin no process id. Discovery therefore goes by program name: a terminal pane counts when the first word of its running command (`pane_command`) is a configured tool. Plugin panes and exited panes are skipped. The rest of the command line is never kept.
- A session id is `zellij:<session>:terminal_<N>`.
- With no process id there is no in-process liveness check. Whether an attached zellij session still runs takes one `list-panes` call, made when the statusline refreshes (at most every 5 s) and when attached sessions are listed. The other backends make no call for this.
- zellij exits 0 when `write-chars` is sent to a pane that does not exist, and drops the text. So `send` first checks the pane, and a pane that is gone or has exited is refused before anything is written.
- Start opens a pane to the right of Neovim's pane in Neovim's own session, without focus. zellij has no environment flag for it, so a tool `env` is passed as `/usr/bin/env K=V command`. `focus` focuses the pane by id.
- Start returns once the new pane's program name is the tool, waiting up to 2 s while Neovim keeps running. If the name never shows (a tool installed as a `node` or `python` script shows as the interpreter, until a script-name rule exists), start fails and the new pane is left open.
- Focus is verified within one tab only. Focusing a pane in another tab is unverified.

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

Under lazy.nvim, set `keys` through `opts`. The triggers come from `opts.keys`, not from the arguments of a `setup()` call in your own `config`: with `config = function() require("sidekick-ultra").setup({ keys = false }) end` and no `opts`, the triggers still appear at `<leader>a`, and pressing one loads the plugin without defining the map.

## Commands

`:SidekickUltra <sub> [key=value ...]`. Values may be double-quoted, with `\"` and `\\` escapes. `true` and `false` are booleans for boolean keys. Arguments are parsed, never evaluated. With a range (`:'<,'>SidekickUltra send ...`) the last visual selection is restored first, so `{selection}` works.

| Subcommand | Keys | Does |
|---|---|---|
| `select` | `name`, `focus` | pick a session or tool, attach it; a tool without a session is started next to Neovim |
| `send` | `msg`, `prompt`, `name`, `submit`, `focus` | render the message or prompt and send it to the target session |
| `prompt` | `name`, `submit`, `focus` | pick a prompt and send it |
| `focus` | `name` | focus the target's pane or block |
| `close` | `name`, `all` | detach (the tool keeps running) |

A tool that `select`, `send`, `prompt` or `focus` starts is focused once it is up. The new pane or block is created unfocused and then focused through the multiplexer. Pass `focus=false` (Lua: `focus = false`) to `select`, `send` or `prompt` to keep your own focus. A failed focus is reported, and the session stays attached and still receives the text. `focus` takes no `focus` key: it always focuses. On `send`, `focus=true` also focuses the session after delivery, whether or not the tool was just started.

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

One entry per attached session, with `state` set when the backend reports one. The list is cached for 5 s. Refreshing it checks that each attached session still runs: an in-process pid check for herdr, rex and tmux, and one `zellij` call per attached zellij session. Events `User SidekickUltraAttach` and `User SidekickUltraDetach` carry `data = { id = ... }`.

## Safety

- On herdr and rex, `send` re-reads the session state first and refuses (`session_blocked`) when the agent is blocked on a prompt, and refuses (`status_unreadable`) when the state cannot be read. tmux and zellij have no agent status and no such guard.
- Starting a tool is allowed only when Neovim runs inside that multiplexer (`not_in_mux` otherwise). If it runs inside several, `TERM_PROGRAM` decides: the backend whose name it equals is used, and anything else is `not_in_mux`. herdr, rex and tmux set `TERM_PROGRAM` to their own name; zellij does not, so inside zellij nested in another multiplexer the outer one is chosen if `TERM_PROGRAM` names it, and otherwise start is refused.
- Notifications carry a stable error id: `not_in_mux`, `session_blocked`, `status_unreadable`, `not_installed`, `no_match`, `nothing_to_send`, `unknown_context`, `unknown_prompt`, `render_failed`, `backend_error`, `duplicate_session`, `invalid_command`, `incomplete_command`, `invalid_args`.

## Health

`:checkhealth sidekick-ultra` reports the Neovim version, each backend (enabled, binary path and where it came from, server settings by variable name only), for tmux and zellij also whether Neovim runs inside them and their version (`tmux -V`, `zellij --version`), whether `tmux.socket` is set, whether Neovim runs inside any of the four multiplexers, whether the textobjects queries are available, and which tools are installed.

## Development

```sh
make check        # stylua --check, selene, and the test suite
make test-floor   # the suite under Neovim 0.11.2 (NVIM=/tmp/sku-nvim-0.11/nvim-macos-arm64/bin/nvim)
```

`scripts/test` clones mini.test at a pinned commit into `.tests/deps`, runs the specs in an isolated HOME with stub `herdr`, `rex`, `tmux` and `zellij` binaries first on `PATH` (a stub that is reached prints `stub reached` and exits 97), and bounds the run at 300 s. The backend contract is documented in `lua/sidekick-ultra/backend.lua`.

## License

MIT. See `LICENSE`.
