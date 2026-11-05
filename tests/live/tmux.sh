#!/bin/sh
# DRAFT for D8. Live run of the tmux backend against a private tmux server and stub agent CLIs.
# Never run by the engineer who wrote it. The Lead sends this recipe to the Supervisor before the first run.
#
# What it does: starts a private tmux server on the socket /tmp/sku-live-tmux/tmux.sock (own HOME, TMPDIR and
# TMUX_TMPDIR, `-f /dev/null`), creates three panes (a stub claude below a shell, a stub codex as the pane's own
# process in a second session, a plain shell for nvim), and drives headless nvim with the plugin:
#   outside the mux (tmux.socket = the private socket): discover across sessions, attach, send (no Enter), submit, focus,
#                    the not_in_mux start refusal, and "no server" meaning no sessions;
#   inside the mux (nvim typed into the shell pane, no tmux.socket): inside(), start through registry.start (the new pane
#                    is focused, D7), running at once, rediscovery, send and submit.
# Then it tears everything down: `kill-server` on the private socket, then `rm -rf` of the literal root.
#
# Every tmux call it makes (and the plugin makes, outside) names the private socket with -S. It never uses -L, the
# default server, the Human's sessions or any /tmp/munsu-e2e.* server. The stubs are symlinks to /bin/cat, so a typed
# line is echoed by the tty and printed again by cat once Enter arrives; nothing is interpreted by a shell.
#
# D9 adds two script stubs, each the own process of a pane in the session "other": `gemini` (a python script,
# `#!/usr/bin/python3`) and `qwen` (a node script, `#!/usr/bin/env node`, run by a symlink named node to the mise node
# binary). They run as their interpreter, so discovery must read the script name through one `ps` call. They read stdin
# and never print their own arguments; the driver logs only the session fields and the interpreter's process name.
set -eu

[ "${SKU_LIVE:-}" = 1 ] || {
  echo "refusing: set SKU_LIVE=1 to run the live tmux test" >&2
  exit 2
}

R=/tmp/sku-live-tmux
here=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$here/../.." && pwd -P)
case "$REPO" in
  *[!A-Za-z0-9/._-]*)
    echo "refusing: repo path has characters that cannot be typed into a pane shell safely: $REPO" >&2
    exit 2
    ;;
esac

say() { printf '+ %s\n' "$*" >&2; }
die() {
  echo "FATAL: $*" >&2
  exit 1
}

# Resolved now, with the caller's PATH, and only ever executed with the isolated environment below.
TMUX_BIN=$(command -v tmux) || die "tmux is not on PATH"
NVIM=$(command -v nvim) || die "nvim is not on PATH"
case "$TMUX_BIN" in */tests/bin/*) die "tmux resolves to a test stub: $TMUX_BIN" ;; esac

[ -e "$R" ] && die "$R already exists; remove it yourself after looking at it"

CREATED=0
SERVER_PID=
SOCK="$R/tmux.sock"

# The one PATH every pane, client and nvim driver gets: the stubs and tmux's symlink, then the system dirs. No host bin
# directory, so the real claude and codex CLIs are not reachable even if a stub goes missing.
ISO_PATH="$R/bin:/usr/bin:/bin"

# The one environment every tmux client, the server and the nvim driver run in, as `env` words: an allowlist, `env -i`
# plus explicit assignments. A `-u` blocklist can never be complete. TMUX_TMPDIR sits under the root, so even a call
# that forgot -S could only reach a socket inside the root. Every value is a plain word (the root is a literal path,
# the user name comes from `id -un`), so none has a space or a glob character and the unquoted expansions split right.
USER_NAME=$(id -un)
TM_ENV="-i HOME=$R/home TMPDIR=$R/tmp TMUX_TMPDIR=$R/tmp PATH=$ISO_PATH LANG=en_US.UTF-8 TERM=xterm-256color
  SHELL=/bin/sh USER=$USER_NAME LOGNAME=$USER_NAME"

tm_env() {
  # shellcheck disable=SC2086
  env $TM_ENV "$@"
}

# Every tmux call of this script: the private socket, no config file.
tm() {
  say tmux -S "$SOCK" -f /dev/null "$@"
  tm_env "$TMUX_BIN" -S "$SOCK" -f /dev/null "$@"
}

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ "$CREATED" = 1 ]; then
    # The server exists from the first new-session, before SERVER_PID is recorded, so ask it to exit whenever the root
    # was made. With no server this only prints an error. The recorded pid is the fallback.
    tm kill-server 2>/dev/null || true
    sleep 1
    if [ -n "$SERVER_PID" ]; then
      if kill -0 "$SERVER_PID" 2>/dev/null; then
        say kill "$SERVER_PID"
        kill "$SERVER_PID" 2>/dev/null || true
        sleep 2
      fi
      if kill -0 "$SERVER_PID" 2>/dev/null; then
        say kill -KILL "$SERVER_PID"
        kill -KILL "$SERVER_PID" 2>/dev/null || true
      fi
    fi
    say rm -rf /tmp/sku-live-tmux
    rm -rf /tmp/sku-live-tmux
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# --- root, stubs -------------------------------------------------------------------------------------------------
say mkdir "$R"
mkdir "$R"
CREATED=1
mkdir "$R/bin" "$R/home" "$R/tmp" "$R/work" "$R/out"
# nvim's driver and the plugin call `tmux` by name; the isolated PATH finds this link. The script runs $TMUX_BIN.
ln -s "$TMUX_BIN" "$R/bin/tmux"

# Stub agents: symlinks to /bin/cat named claude and codex. nvim reads the invoked name, so a symlink answers to its own
# name (checked with nvim_get_proc on this Mac). A copy of /bin/cat is killed by macOS when run from another path, and a
# shell script would answer as bash.
for name in claude codex; do
  ln -s /bin/cat "$R/bin/$name"
done

# Script stubs (D9). The python one runs under the system python3; the node one under the mise node binary, linked as
# `node` into the root's bin. `#!/usr/bin/env node` rather than a literal `#!$R/bin/node`: it is the form npm gives a
# global bin, so the process is `node <script>` with argv0 `node`, as in real use; the isolated PATH below makes env find
# the link, and the preflight refuses to go on unless it does.
NODE_BIN=/Users/beowulf/.local/share/mise/installs/node/lts/bin/node
[ -x "$NODE_BIN" ] || die "preflight: $NODE_BIN is not executable"
[ -x /usr/bin/python3 ] || die "preflight: /usr/bin/python3 is not executable"
ln -s "$NODE_BIN" "$R/bin/node"
cat >"$R/bin/gemini" <<'STUB_PY'
#!/usr/bin/python3
import sys

while sys.stdin.readline():
    pass
STUB_PY
cat >"$R/bin/qwen" <<'STUB_JS'
#!/usr/bin/env node
process.stdin.resume();
STUB_JS
chmod 755 "$R/bin/gemini" "$R/bin/qwen"

# Refuse unless the stubs win: under the exact isolated PATH, claude, codex and tmux must resolve to the files made
# above. The pane shells type the bare names, so a missing or unusable stub would run a real CLI.
for name in claude codex tmux; do
  found=$(
    PATH=$ISO_PATH
    command -v "$name"
  ) || found=
  if [ "$found" != "$R/bin/$name" ] || [ ! -x "$R/bin/$name" ]; then
    echo "refusing: $name resolves to '$found' under PATH=$ISO_PATH, not to $R/bin/$name" >&2
    exit 2
  fi
done
# Each stub must be exactly a symlink to /bin/cat, and it must run (cat exits 0 on EOF at once).
for name in claude codex; do
  if [ ! -L "$R/bin/$name" ] || [ "$(readlink "$R/bin/$name")" != /bin/cat ]; then
    echo "refusing: $R/bin/$name is not a symlink to /bin/cat" >&2
    exit 2
  fi
  "$R/bin/$name" </dev/null || {
    echo "refusing: the stub $R/bin/$name does not run" >&2
    exit 2
  }
done

# Script stub preflight: gemini, qwen and node must resolve to the files made above under the exact isolated PATH; node
# must be exactly a symlink to the mise node binary; each script must start with the expected interpreter line, and run
# and end at once on an empty stdin under the pane environment.
for name in gemini qwen node; do
  found=$(
    PATH=$ISO_PATH
    command -v "$name"
  ) || found=
  if [ "$found" != "$R/bin/$name" ] || [ ! -x "$R/bin/$name" ]; then
    echo "refusing: $name resolves to '$found' under PATH=$ISO_PATH, not to $R/bin/$name" >&2
    exit 2
  fi
done
if [ ! -L "$R/bin/node" ] || [ "$(readlink "$R/bin/node")" != "$NODE_BIN" ]; then
  echo "refusing: $R/bin/node is not a symlink to $NODE_BIN" >&2
  exit 2
fi
[ "$(head -n 1 "$R/bin/gemini")" = "#!/usr/bin/python3" ] || die "preflight: the gemini stub has an unexpected first line"
[ "$(head -n 1 "$R/bin/qwen")" = "#!/usr/bin/env node" ] || die "preflight: the qwen stub has an unexpected first line"
for name in gemini qwen; do
  tm_env "$R/bin/$name" </dev/null || {
    echo "refusing: the stub $R/bin/$name does not run under the pane environment" >&2
    exit 2
  }
done

# Socket preflight: the path must be under the root and short enough for a unix socket.
case "$SOCK" in
  /tmp/sku-live-tmux/*) ;;
  *) die "socket path is not under the root: $SOCK" ;;
esac
[ "${#SOCK}" -lt 100 ] || die "socket path is too long for a unix socket: $SOCK"
[ ! -e "$SOCK" ] || die "a socket already exists at $SOCK"

cat >"$R/drive.lua" <<'EOF'
-- Driver run by headless nvim. Environment: SKU_REPO, SKU_OUT, SKU_PHASE, SKU_SOCK, SKU_CWD, SKU_CLAUDE_PANE,
-- SKU_CODEX_PANE, SKU_SHELL_PANE, SKU_GEMINI_PANE, SKU_QWEN_PANE. Every tmux call of this driver names the private
-- socket.
local repo, out, phase = os.getenv("SKU_REPO"), os.getenv("SKU_OUT"), os.getenv("SKU_PHASE")
local sock = os.getenv("SKU_SOCK")
vim.opt.rtp:prepend(repo)

local function log(line)
  local file = assert(io.open(out, "a"))
  file:write(line .. "\n")
  file:close()
end
local function check(name, ok, detail)
  log((ok and "PASS " or "FAIL ") .. name .. (ok and "" or (": " .. vim.inspect(detail))))
end
local function observe(name, value)
  log("OBSERVE " .. name .. " = " .. vim.inspect(value))
end
local function tmux(...)
  local res = vim.system({ "tmux", "-S", sock, "-f", "/dev/null", ... }, { text = true }):wait()
  return vim.trim(res.stdout or ""), res.code
end
local function screen(pane)
  return (tmux("capture-pane", "-p", "-J", "-t", pane))
end
---Lines of the pane's screen that contain `needle`.
local function count(pane, needle)
  local n = 0
  for _, line in ipairs(vim.split(screen(pane), "\n", { plain = true })) do
    if line:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end
local function format(pane, fmt)
  return (tmux("display-message", "-p", "-t", pane, fmt))
end
local function pane_count()
  local listing = tmux("list-panes", "-a", "-F", "#{pane_id}")
  return #vim.split(listing, "\n", { plain = true, trimempty = true })
end
local function find(sessions, id)
  for _, s in ipairs(sessions) do
    if s.id == id then
      return s
    end
  end
end
local function real(path)
  return vim.uv.fs_realpath(path) or path
end

local function run()
  local claude_pane, codex_pane, shell_pane =
    os.getenv("SKU_CLAUDE_PANE"), os.getenv("SKU_CODEX_PANE"), os.getenv("SKU_SHELL_PANE")
  local claude_id, codex_id = "tmux:" .. claude_pane, "tmux:" .. codex_pane
  local cfg = { herdr = { enabled = false }, rex = { enabled = false }, zellij = { enabled = false } }
  -- Outside the mux the socket is explicit; inside, no socket: a bare tmux reaches the pane's own server (TMUX).
  cfg.tmux = phase == "start" and {} or { socket = sock }
  if phase == "noserver" then
    cfg.tmux = { socket = os.getenv("SKU_CWD") .. "/absent.sock" }
  end
  require("sidekick-ultra").setup(cfg)
  local registry = require("sidekick-ultra.registry")
  local tools = require("sidekick-ultra.tools")
  local backend = registry.backend("tmux")
  check("tmux backend registered", backend ~= nil)
  if not backend then
    return
  end

  if phase == "basic" then
    check("inside() is false outside the mux", backend.inside() == false)
    local sessions = registry.discover()
    local claude, codex = find(sessions, claude_id), find(sessions, codex_id)
    check("discover finds the stub claude below a shell", claude ~= nil and claude.tool == "claude", sessions)
    check("discover finds the stub codex in the other session", codex ~= nil and codex.tool == "codex", sessions)
    -- D9: tools installed as scripts run as their interpreter; discovery reads the script name through one ps call. The
    -- sessions hold no command line, so they may be printed. The interpreter's process name is observed, not assumed.
    local gemini_session = find(sessions, "tmux:" .. os.getenv("SKU_GEMINI_PANE"))
    local qwen_session = find(sessions, "tmux:" .. os.getenv("SKU_QWEN_PANE"))
    check("discover finds the python script stub as gemini", gemini_session ~= nil and gemini_session.tool == "gemini", sessions)
    check("discover finds the node script stub as qwen", qwen_session ~= nil and qwen_session.tool == "qwen", sessions)
    if gemini_session and qwen_session then
      observe("python script stub process name", gemini_session.proc_name)
      observe("node script stub process name", qwen_session.proc_name)
      check("the script stubs are running", registry.is_running(gemini_session) and registry.is_running(qwen_session), { gemini_session, qwen_session })
    end
    check("discover finds nothing else", #sessions == 4, sessions)
    if not (claude and codex) then
      return
    end
    check("cwd matches the pane cwd", real(claude.cwd) == real(os.getenv("SKU_CWD")), claude.cwd)
    check("sessions are in different tmux sessions", claude.tmux_session ~= codex.tmux_session, { claude, codex })
    check("session is running", registry.is_running(claude), claude)
    observe("claude session", claude)
    observe("codex session", codex)

    check("attach", registry.attach(claude) == true)
    check("attached() keeps it", #registry.attached() == 1)

    local ok, err = backend.send(claude, "hello-live")
    check("send succeeds", ok == true, err)
    vim.wait(800)
    check("sent text reaches the pane once (tty echo)", count(claude_pane, "hello-live") == 1, screen(claude_pane))
    ok, err = backend.submit(claude)
    check("submit succeeds", ok == true, err)
    vim.wait(800)
    check("submit presses Enter (cat prints the line)", count(claude_pane, "hello-live") == 2, screen(claude_pane))
    check("no paste buffer is left", tmux("list-buffers") == "", tmux("list-buffers"))

    ok, err = backend.send(claude, "")
    check("an empty send is a no-op", ok == true, err)

    -- A pane scrolled back into copy mode takes keys and pastes for the mode, not for the program: send and submit
    -- must leave the mode first. Enter the mode before each call, so each path is checked on its own.
    local _, mode_code = tmux("copy-mode", "-t", claude_pane)
    check("the claude pane enters copy mode", mode_code == 0 and format(claude_pane, "#{pane_in_mode}") == "1", mode_code)
    ok, err = backend.send(claude, "mode-live")
    check("send succeeds on a pane in copy mode", ok == true, err)
    vim.wait(800)
    check("send left copy mode", format(claude_pane, "#{pane_in_mode}") == "0", format(claude_pane, "#{pane_in_mode}"))
    check("the text reaches the program once", count(claude_pane, "mode-live") == 1, screen(claude_pane))
    _, mode_code = tmux("copy-mode", "-t", claude_pane)
    check("the claude pane enters copy mode again", mode_code == 0 and format(claude_pane, "#{pane_in_mode}") == "1", mode_code)
    ok, err = backend.submit(claude)
    check("submit succeeds on a pane in copy mode", ok == true, err)
    vim.wait(800)
    check("submit left copy mode", format(claude_pane, "#{pane_in_mode}") == "0", format(claude_pane, "#{pane_in_mode}"))
    check("the line is echoed by the program", count(claude_pane, "mode-live") == 2, screen(claude_pane))
    check("no paste buffer is left after the mode checks", tmux("list-buffers") == "", tmux("list-buffers"))

    -- Raw bytes: tmux 3.7+ passes a pasted buffer through vis(3) unless paste-buffer has -S, which turns an ESC byte
    -- into visible characters (\033 or \^[). The text holds ESC [ 0 m (an SGR reset: harmless) between two printable
    -- markers. The pane's tty echoes a raw ESC as "^[" (echoctl); vis text would be echoed with a backslash. After
    -- Enter, cat prints the line back: a raw ESC [ 0 m is a complete sequence that the terminal consumes, so the markers touch;
    -- vis text would be printed as visible characters.
    ok, err = backend.send(claude, "esc-live-\27[0m-end")
    check("send of a text with an ESC byte succeeds", ok == true, err)
    vim.wait(800)
    check("the tty echoes the ESC byte as ^[", count(claude_pane, "esc-live-^[[0m-end") == 1, screen(claude_pane))
    check("no vis-escaped ESC reached the program", screen(claude_pane):find("esc-live-\\", 1, true) == nil, screen(claude_pane))
    ok, err = backend.submit(claude)
    check("submit of the ESC line succeeds", ok == true, err)
    vim.wait(800)
    check(
      "the program printed the raw ESC sequence (consumed by the terminal)",
      count(claude_pane, "esc-live--end") == 1 and count(claude_pane, "esc-live-^[[0m-end") == 1,
      screen(claude_pane)
    )

    local gone = vim.tbl_extend("force", claude, { pane = "%999", id = "tmux:%999" })
    ok, err = backend.send(gone, "nope-live")
    check("send to a missing pane fails", ok == nil and err and err.id == "backend_error", err)
    observe("missing pane error", err and err.msg)
    -- tmux answers the mode check for a missing pane with exit 0 and no output (seen live at 58637a7); the backend names
    -- the pane. The check fails first, so no buffer is loaded: this no longer reaches the delete-buffer cleanup after a
    -- failed paste (a dead pane might, but whether tmux then fails the paste or skips it is not known).
    check(
      "the missing pane is named plainly",
      err ~= nil and err.cmd == "display-message" and err.msg == "tmux pane %999 not found",
      err
    )
    check("a send to a missing pane loads no paste buffer", tmux("list-buffers") == "", tmux("list-buffers"))

    ok, err = backend.focus(codex)
    check("focus a pane in another session", ok == true, err)
    check(
      "the pane is active in its window",
      format(codex_pane, "#{pane_active}") == "1" and format(codex_pane, "#{window_active}") == "1",
      { format(codex_pane, "#{pane_active}"), format(codex_pane, "#{window_active}") }
    )
    ok, err = backend.focus(claude)
    check("focus the claude pane", ok == true and format(claude_pane, "#{pane_active}") == "1", err)

    local before = pane_count()
    local started, start_err = registry.start(tools.get("claude"))
    check("start outside the mux is refused", started == nil and start_err and start_err.id == "not_in_mux", start_err)
    check("refused start created no pane", pane_count() == before)
  elseif phase == "noserver" then
    local notified = {}
    vim.notify = function(msg)
      table.insert(notified, msg)
    end
    local sessions = registry.discover()
    check("discover with no server lists nothing", #sessions == 0, sessions)
    check("and reports nothing", #notified == 0, notified)
    local list, err = backend.list(tools.all())
    observe("list with no server", { list, err })
  elseif phase == "start" then
    check("inside() is true in the pane", backend.inside() == true)
    check("start_backend picks tmux", (registry.start_backend()) == backend)
    local before = pane_count()
    local session, err = registry.start(tools.get("claude"))
    check("start returns a session", session ~= nil, err)
    if not session then
      return
    end
    observe("started session", session)
    check("started session is running at once", registry.is_running(session), session)
    check("start created exactly one pane", pane_count() == before + 1)
    check(
      "the new pane is beside nvim's own",
      format(session.pane, "#{window_id}") == format(shell_pane, "#{window_id}"),
      { format(session.pane, "#{window_id}"), format(shell_pane, "#{window_id}") }
    )
    check(
      "start focused the new pane, not nvim's (D7)",
      format(session.pane, "#{pane_active}") == "1" and format(shell_pane, "#{pane_active}") == "0",
      { format(session.pane, "#{pane_active}"), format(shell_pane, "#{pane_active}") }
    )
    check("attach started session", registry.attach(session) == true)
    vim.wait(1500)
    local fresh = find(registry.discover(), session.id)
    check("rediscovery lists the started pane", fresh ~= nil and fresh.tool == "claude", fresh)
    if fresh then
      observe("rediscovered session", fresh)
      check("rediscovered session is running", registry.is_running(fresh), fresh)
      check("attached entry survived rediscovery", #registry.attached() == 1)
      local ok, send_err = backend.send(fresh, "start-live")
      check("send to the started pane", ok == true, send_err)
      vim.wait(800)
      check("started pane shows the text once", count(session.pane, "start-live") == 1, screen(session.pane))
      ok, send_err = backend.submit(fresh)
      check("submit to the started pane", ok == true, send_err)
      vim.wait(800)
      check("started pane echoes the line", count(session.pane, "start-live") == 2, screen(session.pane))
    end
    log("UNVERIFIABLE switch-client: no client is attached to the private server, so a cross-session focus from inside is not exercised")
  end
end

local ok, err = pcall(run)
if not ok then
  log("FAIL driver error: " .. tostring(err))
end
log("DONE")
vim.cmd("qa!")
EOF

# --- server and panes ----------------------------------------------------------------------------------------------
# Session main: pane A (a /bin/sh that will run the stub claude, depth 1) and pane C (a /bin/sh for nvim).
# Session other: pane B, whose own process is the stub codex (depth 0). default-command keeps later panes non-login, so
# no /etc/profile (path_helper) puts host directories in front of the stubs.
say tmux new-session main
PANE_A=$(tm new-session -d -s main -x 200 -y 50 -c "$R/work" -P -F '#{pane_id}' /bin/sh)
tm set-option -g default-command /bin/sh
PANE_C=$(tm split-window -d -h -t "$PANE_A" -c "$R/work" -P -F '#{pane_id}')
PANE_B=$(tm new-session -d -s other -x 200 -y 50 -c "$R/work" -P -F '#{pane_id}' "$R/bin/codex")
# The script stubs (D9) are the own process of one window each in session other.
PANE_G=$(tm new-window -d -t other: -c "$R/work" -P -F '#{pane_id}' "$R/bin/gemini")
PANE_Q=$(tm new-window -d -t other: -c "$R/work" -P -F '#{pane_id}' "$R/bin/qwen")
for id in "$PANE_A" "$PANE_B" "$PANE_C" "$PANE_G" "$PANE_Q"; do
  case "$id" in %[0-9]*) ;; *) die "could not read a pane id from tmux: '$id'" ;; esac
done
echo "panes: claude=$PANE_A codex=$PANE_B shell=$PANE_C gemini=$PANE_G qwen=$PANE_Q"

# Socket preflight against the live server: it is the private one, and it holds only what this script made.
[ -S "$SOCK" ] || die "no socket at $SOCK"
SERVER_PID=$(tm display-message -p '#{pid}')
[ "$(tm display-message -p '#{socket_path}')" = "$SOCK" ] || die "the server does not report $SOCK as its socket"
[ "$(tm list-sessions -F '#{session_name}' | sort | tr '\n' ' ')" = "main other " ] || die "the private server holds unexpected sessions"
echo "$SERVER_PID" >"$R/server.pid"

tm send-keys -t "$PANE_A" -l claude
tm send-keys -t "$PANE_A" Enter
sleep 1

# --- drive nvim outside the mux ----------------------------------------------------------------------------------
nv() {
  phase=$1
  say nvim "(headless, phase $phase, output $R/out/$phase.txt)"
  tm_env \
    SKU_REPO="$REPO" SKU_OUT="$R/out/$phase.txt" SKU_PHASE="$phase" SKU_SOCK="$SOCK" SKU_CWD="$R/work" \
    SKU_CLAUDE_PANE="$PANE_A" SKU_CODEX_PANE="$PANE_B" SKU_SHELL_PANE="$PANE_C" \
    SKU_GEMINI_PANE="$PANE_G" SKU_QWEN_PANE="$PANE_Q" \
    /usr/bin/perl -e 'alarm 90; exec @ARGV' -- "$NVIM" --headless -u NONE -i NONE -l "$R/drive.lua" || true
}

nv basic
nv noserver

# --- drive nvim inside the mux: typed into pane C, which gives it TMUX, TMUX_PANE and TERM_PROGRAM=tmux ----------------
CMD="SKU_REPO=$REPO SKU_OUT=$R/out/start.txt SKU_PHASE=start SKU_SOCK=$SOCK SKU_CWD=$R/work SKU_CLAUDE_PANE=$PANE_A SKU_CODEX_PANE=$PANE_B SKU_SHELL_PANE=$PANE_C /usr/bin/perl -e 'alarm 90; exec @ARGV' -- $NVIM --headless -u NONE -i NONE -l $R/drive.lua"
tm send-keys -t "$PANE_C" -l "$CMD"
tm send-keys -t "$PANE_C" Enter
n=0
until grep -q '^DONE' "$R/out/start.txt" 2>/dev/null; do
  n=$((n + 1))
  [ "$n" -le 120 ] || {
    echo "inside phase did not finish within 60 s" >&2
    break
  }
  sleep 0.5
done

# --- report ------------------------------------------------------------------------------------------------------
fail=0
for phase in basic noserver start; do
  echo "== $phase"
  cat "$R/out/$phase.txt" 2>/dev/null || {
    echo "FAIL no output for phase $phase"
    fail=1
  }
  if grep -q '^FAIL' "$R/out/$phase.txt" 2>/dev/null; then fail=1; fi
  grep -q '^DONE' "$R/out/$phase.txt" 2>/dev/null || fail=1
done
if [ "$fail" = 0 ]; then
  echo "LIVE tmux: all checks passed"
else
  echo "LIVE tmux: FAILED"
fi
exit "$fail"
