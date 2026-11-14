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
    bin = nil,    -- non-empty path to the rex binary; default: rex on PATH, then the Rex Beta app bundle
    server = nil, -- non-empty; passed to rex as -S <server>
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
  -- Extra `{placeholders}`, named with letters, digits and underscores (not `this`): a function of the snapshot
  -- returning a string, a list of strings, or nil.
  context = {
    branch = function(snap)
      return vim.trim(vim.fn.system({ "git", "-C", snap.cwd, "branch", "--show-current" }))
    end,
  },
}
```

Tool fields: `cmd` (non-empty list), `env`, `url`, `is_proc` (Vim regex or a function of `{ pid, cmd }`, where `cmd` is one program name and `pid` is absent on zellij; the default matches the basename of `cmd[1]` as a word, and a built-in keeps its own program name when you change its `cmd`), `mux_focus` (send a focus-in event before input), `location` (`plain`, `claude` or `escaped`: how file locations are written in sent text).

Built-in tools: aider, amazon_q, claude, codex, copilot, crush, cursor, gemini, grok, opencode, pi, qwen.

## tmux and zellij

Both are backends like herdr and rex: they list the panes that run a configured tool, start a tool in a new pane beside Neovim's own, send text, press Enter and focus a pane. Each is enabled by default and registered when its binary is found; `tmux = { enabled = false }` or `zellij = { enabled = false }` turns one off.

What they do not have is an agent status. herdr and rex tell the plugin when an agent is blocked on a prompt; tmux and zellij do not. So on tmux and zellij `send` never refuses with `session_blocked` or `status_unreadable`: the text goes to the pane whatever the tool is doing. (tmux still refuses a pane whose tool is no longer in the foreground, with a `backend_error`, and so does herdr beside its state guard; see below.)

**tmux** (checked against tmux 3.8)

- Neovim counts as inside tmux when `TMUX` and `TMUX_PANE` are set, and, if `tmux.socket` is set, when the server in `TMUX` is that socket (compared after normalizing and resolving the path); otherwise start is refused with `not_in_mux`. Starting a tool is allowed only when inside.
- Without `tmux.socket`, calls go to the server named by `TMUX`, or to tmux's default server when Neovim runs outside tmux. With `socket`, every call is `tmux -S <socket> ...`. Set it to reach a private server from an editor that runs outside tmux.
- Discovery lists every pane of the server, in all sessions, with one `list-panes -a` call, and skips dead panes. A pane counts when a process in its process tree (the pane's own process and everything below it) is a configured tool. The tree is read with Neovim's `nvim_get_proc` and `nvim_get_proc_children`, which on Unix fall back to Neovim's own `ps` calls (two per pid) and `pgrep`; the plugin runs none of them. A tool installed as a node or python script runs as its interpreter, so for a process named `node`, `nodejs`, `bun`, `python`, `python3`, `python3.<N>` or `Python`, and only those, one `ps -ww -o args= -p <pid>` call reads the command line, and the script's name is matched instead (see below). No other command line and no environment is read. A process that ended before `ps` ran (exit 1, nothing printed) is skipped; any other failing `ps` is a `backend_error` naming the pid and the exit code. No running server means no sessions, not an error.
- A matched pane is kept only when the matched process is the pane's foreground program. `list-panes` also prints `#{pane_current_command}`, and one `ps -o ucomm= -p <pid>` call per matched pane (none for other panes) reads the kernel short name of the matched pid; the pane is kept when the two are equal. The plugin's own name for a process cannot be compared with tmux's, because the two can differ: the plugin's name for Claude Code is `claude`, the basename of the path it was started by (the `~/.local/bin/claude` symlink), while `ucomm` is the name of the executable the symlink points to, here `2.1.322`; and a program that sets its process title (a node script) keeps its executable's name (`node`) as `ucomm`. That `ucomm` is what tmux shows as `#{pane_current_command}` was probed on macOS only; Linux is unverified. A pid that ended before `ps` ran drops the pane; any other failing `ps` is a `backend_error` naming the pid and the exit code. So a tool that is suspended (`C-z`), runs in the background (`&`), or runs inside another Neovim's `:terminal` is not discovered over tmux.
- `send` makes the same check again, because an attached session outlives the tool's time in the foreground: before it pastes, one `display-message` reads `#{pane_current_command}` and one `ps -o ucomm=` reads the session's pid, and `send` is refused with a `backend_error` (nothing is sent) when they differ, when the process is gone, or when either call fails. Otherwise the text would reach the shell, which runs it. `submit` is not checked: Enter alone runs nothing new.
- A session id is `tmux:%N`, with the pane id tmux gives.
- Start splits to the right of Neovim's pane without focus, in Neovim's directory, with the tool's `env` as `-e K=V`.
- tmux 3.7 or newer is required: `send` pastes with `paste-buffer -S` (new in 3.7), which keeps control characters as the bytes they are. `:checkhealth` warns below 3.7.
- `send` pastes the text through a temporary tmux buffer with no Enter, and line feeds stay line feeds. `submit` sends Enter. Both first leave copy mode (or any other pane mode) if the pane is in one, since a pane in a mode takes keys and pastes for the mode instead of the program.
- `focus` selects the pane's window and the pane. When Neovim runs inside tmux and the pane is in another session, it also switches the client to it.

**zellij** (checked against zellij 0.45.1)

- Neovim counts as inside zellij when `ZELLIJ`, `ZELLIJ_PANE_ID` and `ZELLIJ_SESSION_NAME` are set. Calls inside zellij go to that session. Outside zellij, discovery asks every session in turn. There is no zellij option besides `enabled`.
- zellij gives the plugin no process id. Discovery therefore goes by program name: a terminal pane counts when the first word of its running command (`pane_command`) is a configured tool, or, when that word is a node or python interpreter, when the script's name is (see below). Plugin panes and exited panes are skipped. The rest of the command line is never kept.
- A session id is `zellij:<session>:terminal_<N>`.
- With no process id there is no pid check (the one herdr, rex and tmux do through Neovim's proc fallback, which on Unix runs `ps`): whether an attached zellij session still runs takes one `list-panes` call (see Statusline for when it runs).
- zellij exits 0 when `write-chars` is sent to a pane that does not exist, and drops the text. So `send` first checks the pane, and a pane that is gone or has exited is refused before anything is written.
- Start opens a pane to the right of Neovim's pane in Neovim's own session, without focus. zellij has no environment flag for it, so a tool `env` is passed as `/usr/bin/env K=V command`. `focus` focuses the pane by id.
- Start returns once the new pane's program name is the tool, waiting up to 2 s while Neovim keeps running. If the name never shows, start fails and the new pane is left open.
- Focus is verified within one tab only. Focusing a pane in another tab is unverified.

**Tools run as node or python scripts** (gemini, qwen, copilot, pi and grok run on node; aider on python). On tmux and zellij the program of a process or pane is then the interpreter, so the script's name is read instead. On rex the foreground's `argv0` and name are tested first, and only when neither matches and one is an interpreter is the script's name read, with one `ps` call for the foreground's pid. A launcher that execs a node script (pi) runs as `node` until the script sets its own process title; rex is meant to find it through the script in the meantime, but that reading has not been seen on a live rex (`tests/fixtures/rex/UNVERIFIED.txt`). The interpreter is `node`, `nodejs`, `bun`, `python`, `python3`, `python3.<N>` or `Python` (the macOS framework binary's name), and the script is the first word that is not a flag. Flags that take a value are skipped with their value: for node and bun the options `node --help` lists with one (`-r`, `--require`, `--import`, `--loader`, `-C`, `--conditions`, `--title`, `--env-file`, and so on, each probed on node v26.13.0; `--config-file`, `--experimental-config-file` and `--experimental-default-config-file` take no separate value), and `-W`, `-X` and `--check-hash-based-pycs` for python. A `--flag=value` word is skipped as one word. `--` makes the next word the script, for node and for python, and `-m <module>` gives the module's name. Code on the command line gives no script and ends the search: `-e`, `--eval`, `-p`, `--print`, `--run`, their `=value` forms, `-c`, and a lone `-` (the script comes from stdin); so does a short cluster with node's `e` or `p` (`-pe`) or python's `c` or `m` (`-uc`, `-cCODE`, `-maider`), which takes the rest of the word as its code or module. Any other python cluster is read left to right the way python 3.9.6 does (its help is silent, this was observed): at the first `W` or `X` the rest of the word is the value, or the next word when it is the last letter (`-Wignore`, `-uW ignore`); a node cluster without `e` or `p` is skipped as one word. The name is the script's basename without one `.js`, `.mjs`, `.cjs` or `.py`; `node .../dist/index.js` is `index` and matches nothing, since npm bins run through their bin-link path, which carries the tool name. An interpreter's own name never matches a tool. Words are split on whitespace, so a script path that holds spaces is misread and matches nothing. Only the script word is read; the rest of the command line is never kept, logged or put into an error.

## Keymaps

`setup()` defines these global maps under `keys.prefix` (default `<leader>a`). Each calls the Lua API. The prefix itself carries the description `+sidekick-ultra` for which-key style menus.

| Keys | Modes | Does |
|---|---|---|
| `<leader>as` | n | `select()`: pick a session or tool |
| `<leader>at` | n, x | `send({ msg = "{this}" })` |
| `<leader>af` | n | `send({ msg = "{file}" })` |
| `<leader>av` | x | `send({ msg = "{selection}" })` |
| `<leader>ap` | n, x | `prompt()`: pick the target, then a prompt |
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

`:SidekickUltra <sub> [key=value ...]`. Values may be double-quoted, with `\"` and `\\` escapes. `true` and `false` are booleans for boolean keys. Arguments are parsed, never evaluated. With a range (`:'<,'>SidekickUltra send ...`), `send` and `prompt` restore the last visual selection first, so `{selection}` works. No action leaves Neovim in visual mode.

| Subcommand | Keys | Does |
|---|---|---|
| `select` | `name`, `focus` | pick a session or tool, attach it; a tool without a session is started next to Neovim |
| `send` | `msg`, `prompt`, `name`, `submit`, `focus` | render the message or prompt and send it to the target session |
| `prompt` | `name`, `submit`, `focus` | pick the target session first, then a prompt, and send it to that session |
| `focus` | `name` | focus the target's pane or block |
| `close` | `name`, `all` | detach (the tool keeps running) |

`send` and `prompt` deliver the text followed by a line feed, and when the text does not already end in whitespace, one space goes before that line feed. The space closes a tool's open `@` file-mention completion (a text ending in `@path` would otherwise leave it open and the line feed would go to it). A text that is only a line feed is sent as is. `.render()` and the prompt preview show the text without the space.

A tool that `select`, `send` or `focus` starts is focused once it is up; a tool that `prompt` starts is focused once the prompt picker closes, so the picker keeps your keys. The new pane or block is created unfocused and then focused through the multiplexer. Pass `focus=false` (Lua: `focus = false`) to `select`, `send` or `prompt` to keep your own focus. A failed focus is reported, and the session stays attached and still receives the text. `focus` takes no `focus` key: it always focuses. On `send`, `focus=true` also focuses the session after delivery, whether or not the tool was just started.

The target is the attached session. With none attached, `send`, `prompt` and `focus` open a picker over the matching sessions and tools (a single match is used without asking), and `close` warns that nothing matches. `select` always opens the picker. With several attached, you choose one (except `close all=true`). `prompt` resolves the target before its prompt picker, so a cancelled prompt picker sends nothing and leaves a tool it started running (and focused). In a picker that supports a preview (snacks.nvim as `vim.ui.select`), the preview pane is shown and each prompt previews the exact text that will be sent to that session, in its tool's file-reference style. A prompt that renders nothing or fails in the current context is not listed. The picker is sized once, when it opens, to fit its longest listed prompt: a short prompt gives a small picker and a long one grows it, never wider than snacks' own select picker and never taller than the screen allows. The preview does not wrap, so a line longer than the width is cut at the edge, and the preview takes up to half the screen. The sizes are in `lua/sidekick-ultra/picker.lua`. Other pickers show no preview.

The same actions exist in Lua: `require("sidekick-ultra").send({ msg = "{file}", submit = true })`, `.prompt()`, `.select()`, `.focus()`, `.close()`, and `.render()` (returns the text without sending). They take `name`, `filter` (`name`, `session`, `attached`, `started`, `installed`, `cwd`, `backend`), `submit`, `focus`, `msg`, `prompt`, and `all` for `close`.

## Context

A message is text with `{name}` placeholders. `{a|b}` uses the first alternative that yields something. If a placeholder yields nothing, nothing is sent and the error names it (`render_failed`).

| Placeholder | Yields |
|---|---|
| `{this}` | in a file buffer `{position}`; otherwise the word "this", with `{selection}` added after the whole message |
| `{position}` `{file}` `{line}` | `@path :L10:C5`, `@path`, `@path :L10` for the cursor or selection |
| `{selection}` | the selected text, de-indented |
| `{buffers}` | one `- @path` line per listed file buffer |
| `{diagnostics}` `{diagnostics_all}` | diagnostics of the buffer, or of all buffers |
| `{quickfix}` | the quickfix list |
| `{function}` `{class}` | the enclosing function or class (needs `nvim-treesitter-textobjects`) |

Every control byte in sent text except tab and line feed (selected text, diagnostics, paths, and what you type in a message or prompt template) is sent in caret notation: the byte XOR 0x40 after a `^`, so NUL is `^@`, CR is `^M`, ESC is `^[` and DEL is `^?`. A message or template ending in `\r` therefore no longer submits on tmux (use `submit = true`), and a literal ESC is no longer a key.

Built-in prompts: changes, diagnostics, diagnostics_all, document, explain, fix, optimize, review, tests, plus one per placeholder except `{this}`.

## Statusline

```lua
require("sidekick-ultra.status").cli()
-- { { id = "herdr:w1-1", tool = "claude", cwd = "...", backend = "herdr", state = "idle" }, ... }
```

One entry per attached session, with `state` set when the backend reports one. The list is cached: attach and detach events refresh it, and when it is older than 5 s a refresh first checks that each attached session still runs (a pid check through `nvim_get_proc` for herdr, rex and tmux, which on Unix runs Neovim's own `ps` fallback and calls no multiplexer; one `list-panes` call per attached zellij session). When a check fails, one discovery refreshes the attached sessions before the failing ones are detached: a pane that just started may hold a launcher that has become the tool (zellij and rex are the exceptions: their start waits until the pane or block shows the tool, so their record is never a shell, though on rex a node-run tool or a wrapper named like the tool can match before the final stage). A session is also detached when a backend that listed no longer lists it. Choosing a target for an action runs the same check. Events `User SidekickUltraAttach` and `User SidekickUltraDetach` carry `data = { id = ... }`.

## Safety

- On herdr and rex, `send` re-reads the session state first and refuses (`session_blocked`) when the agent is blocked on a prompt, and refuses (`status_unreadable`) when the state cannot be read. tmux and zellij have no agent status and no such guard.
- On herdr, `send` also reads the pane's foreground process and refuses (`backend_error`, nothing sent) when it is the pane's shell, is not visible to Neovim, or is not the session's tool: a pane that `start` made records its shell, which outlives the tool, so text sent then would be run by the shell. If `herdr agent start` times out while the tool is already in front, `start` fails with the new pane left open, because the tool is alive but not ready; with another program in front it closes the pane.
- Starting a tool is allowed only when Neovim runs inside that multiplexer (`not_in_mux` otherwise). If it runs inside several, `TERM_PROGRAM` decides: the backend whose name it equals is used, and anything else is `not_in_mux`. herdr, rex and tmux set `TERM_PROGRAM` to their own name; zellij does not, so inside zellij nested in another multiplexer the outer one is chosen if `TERM_PROGRAM` names it, and otherwise start is refused.
- A tool's `env` values are passed on the command line of the start command (`-e K=V` on tmux, `--env K=V` on herdr's `pane split`, `/usr/bin/env K=V command` on zellij and rex), so local `ps` shows them. Do not put secrets there.
- Notifications carry a stable error id: `not_in_mux`, `session_blocked`, `status_unreadable`, `not_installed`, `no_match`, `nothing_to_send`, `unknown_context`, `unknown_prompt`, `render_failed`, `backend_error`, `duplicate_session`, `invalid_command`, `incomplete_command`, `invalid_args`.

## Health

`:checkhealth sidekick-ultra` checks the Neovim version against 0.11.2, and reports each backend (enabled, binary path and where it came from, server settings by variable name only), whether Neovim runs inside it, for tmux and zellij also their version (`tmux -V`, `zellij --version`), whether `rex.server` and `tmux.socket` are set, whether start is available (the backend `start` would use, or why there is none), whether the textobjects queries are available, and which tools are installed.

## Development

```sh
make check        # stylua --check, selene, and the test suite
make test-floor   # the suite under Neovim 0.11.2 (NVIM=.tests/nvim-0.11/nvim-macos-arm64/bin/nvim)
```

`scripts/test` clones mini.test at a pinned commit into `.tests/deps`, runs the specs in an isolated HOME with stub `herdr`, `rex`, `tmux` and `zellij` binaries first on `PATH` (a stub that is reached prints `stub reached` and exits 97), and bounds the run at 300 s. The backend contract is documented in `lua/sidekick-ultra/backend.lua`.

## License

MIT. See `LICENSE`.
