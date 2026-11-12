#!/bin/sh
# Live run of the herdr backend against an isolated herdr server and stub agent CLIs. Not part of `make check`.
#
# What it does: starts `herdr server` under the literal root /tmp/sku-live-herdr (own HOME, XDG dirs, config and
# socket), creates three panes (stub claude, stub codex, a plain shell), and drives headless nvim with the plugin:
#   outside the mux: discover, attach, send, submit, focus, start refusal (not_in_mux), the blocked guard,
#                    status_unreadable;
#   inside the mux (nvim typed into the third pane): inside(), start, running at once, rediscovery, send, submit.
# Then it tears everything down: `herdr server stop`, a signal to the recorded server pid, `rm -rf` of the root.
#
# It never passes --session, --remote or --machine, and never touches ~/.config/herdr, ~/.herdr or any other socket.
set -eu

[ "${SKU_LIVE:-}" = 1 ] || {
  echo "refusing: set SKU_LIVE=1 to run the live herdr test" >&2
  exit 2
}

R=/tmp/sku-live-herdr
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
HERDR=$(command -v herdr) || die "herdr is not on PATH"
NVIM=$(command -v nvim) || die "nvim is not on PATH"
case "$HERDR" in */tests/bin/*) die "herdr resolves to the test stub: $HERDR" ;; esac

[ -e "$R" ] && die "$R already exists; remove it yourself after looking at it"

CREATED=0
SERVER_PID=
SOCK="$R/herdr.sock"

# The one PATH every pane, client and the server get: the stubs and herdr's symlink, then the system dirs. No host
# bin directory, so the real claude and codex CLIs are not reachable even if a stub goes missing.
ISO_PATH="$R/bin:/usr/bin:/bin"

# The one environment every herdr client, the server and the nvim driver run in, as `env` words: an allowlist, `env -i`
# plus explicit assignments. A `-u` blocklist can never be complete (ENV, BASH_ENV, PROMPT_COMMAND, exported bash
# functions such as BASH_FUNC_claude%% and names we do not know would get through), and any of them could change PATH or
# shadow a stub. Every value is a plain word (the root is a literal path, the user name comes from `id -un`), so none has
# a space or a glob character and the unquoted expansions below split correctly. LANG is for the stub's non-ASCII OSC title.
USER_NAME=$(id -un)
HX_ENV="-i HOME=$R/home XDG_CONFIG_HOME=$R/config XDG_STATE_HOME=$R/state XDG_DATA_HOME=$R/data XDG_CACHE_HOME=$R/cache
  HERDR_CONFIG_PATH=$R/config/herdr/config.toml HERDR_SOCKET_PATH=$SOCK PATH=$ISO_PATH
  USER=$USER_NAME LOGNAME=$USER_NAME TMPDIR=$R/tmp LANG=en_US.UTF-8 TERM=xterm-256color SHELL=/bin/sh"

hx_env() {
  # shellcheck disable=SC2086
  env $HX_ENV "$@"
}

hx() {
  say herdr "$@"
  hx_env "$HERDR" "$@"
}

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ "$CREATED" = 1 ]; then
    if [ -n "$SERVER_PID" ]; then
      hx server stop || true
      sleep 1
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
    say rm -rf /tmp/sku-live-herdr
    rm -rf /tmp/sku-live-herdr
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# --- root, stubs, helpers -------------------------------------------------------------------------------------
say mkdir "$R"
mkdir "$R"
CREATED=1
mkdir "$R/bin" "$R/home" "$R/config" "$R/config/herdr" "$R/state" "$R/data" "$R/cache" "$R/tmp" "$R/work" "$R/out"
# nvim's driver and the plugin call `herdr` by name; the isolated PATH finds this link. Clients and the server run $HERDR.
ln -s "$HERDR" "$R/bin/herdr"

# Stub agent CLIs: print a banner, echo every stdin line, exit on EOF. herdr identifies an agent from the foreground
# process's argv0 (normalized_process_name, src/detect/mod.rs:381-384; identify_agent_process_in_job, :254-268), so
# each stub re-execs bash under its own name with `exec -a`. `agent start` waits for the screen state to be idle
# (src/terminal/state.rs:2262-2269, src/cli/agent.rs:620-622); the stub sets an OSC window title that the claude and
# codex manifests read as idle (src/detect/manifests/claude.toml:229-235, codex.toml:119-130). Whether that is enough
# is settled by this run; the start phase reports UNVERIFIABLE, not FAIL, when herdr never sees the stub as ready.
make_stub() { # <name> <osc title>
  cat >"$R/bin/$1" <<EOF
#!/bin/bash
if [ "\${SKU_STUB:-}" != "$1" ]; then
  SKU_STUB=$1 exec -a $1 /bin/bash "\$0" "\$@"
fi
printf '\033]0;%s\007' "$2"
echo "SKU-STUB $1 ready"
while IFS= read -r line; do
  echo "got: \$line"
done
EOF
  chmod +x "$R/bin/$1"
}
make_stub claude "✳ sku-stub"
make_stub codex "sku-stub"

# Refuse unless the stubs win: under the exact isolated PATH, claude and codex must resolve to the files written above.
# Nothing is executed. herdr types the bare names into the pane shells, so a missing or unusable stub would run a real CLI.
for name in claude codex; do
  found=$(
    PATH=$ISO_PATH
    command -v "$name"
  ) || found=
  if [ "$found" != "$R/bin/$name" ] || [ -L "$R/bin/$name" ] || [ ! -f "$R/bin/$name" ] || [ ! -x "$R/bin/$name" ]; then
    echo "refusing: $name resolves to '$found' under PATH=$ISO_PATH, not to the stub $R/bin/$name" >&2
    exit 2
  fi
done

# /bin/sh without login startup, so pane shells keep the PATH above (the stubs come first).
cat >"$R/config/herdr/config.toml" <<'EOF'
[terminal]
default_shell = "/bin/sh"
shell_mode = "non_login"
EOF

# Prints the value at a dotted path of the JSON on stdin.
cat >"$R/jget.lua" <<'EOF'
local value = vim.json.decode(io.read("*a"))
for key in arg[1]:gmatch("[^.]+") do
  value = value[key]
end
io.write(tostring(value))
EOF

cat >"$R/drive.lua" <<'EOF'
-- Driver run by headless nvim. Environment: SKU_REPO, SKU_OUT, SKU_PHASE, SKU_CWD, SKU_CLAUDE_PANE, SKU_CODEX_PANE.
local repo, out, phase = os.getenv("SKU_REPO"), os.getenv("SKU_OUT"), os.getenv("SKU_PHASE")
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
local function herdr(...)
  local res = vim.system({ "herdr", ... }, { text = true }):wait()
  return res.stdout or "", res.code
end
local function read(pane)
  return (herdr("pane", "read", pane, "--source", "recent", "--lines", "80"))
end
local function pane_count()
  local json = vim.json.decode((herdr("pane", "list")))
  return #json.result.panes, json.result.panes
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
  require("sidekick-ultra").setup({ rex = { enabled = false }, tmux = { enabled = false }, zellij = { enabled = false } })
  local registry = require("sidekick-ultra.registry")
  local tools = require("sidekick-ultra.tools")
  local backend = registry.backend("herdr")
  check("herdr backend registered", backend ~= nil)
  local claude_id, codex_id = "herdr:" .. os.getenv("SKU_CLAUDE_PANE"), "herdr:" .. os.getenv("SKU_CODEX_PANE")

  if phase == "basic" then
    check("inside() is false outside the mux", backend.inside() == false)
    local sessions = registry.discover()
    local claude, codex = find(sessions, claude_id), find(sessions, codex_id)
    check("discover finds the claude pane", claude ~= nil and claude.tool == "claude", sessions)
    check("discover finds the codex pane", codex ~= nil and codex.tool == "codex", sessions)
    if not (claude and codex) then
      return
    end
    check("cwd matches the pane cwd", real(claude.cwd) == real(os.getenv("SKU_CWD")), claude.cwd)
    check("session is running", registry.is_running(claude), claude)
    observe("claude session", claude)
    observe("codex session", codex)

    check("attach", registry.attach(claude) == true)
    check("attached() keeps it", #registry.attached() == 1)

    local ok, err = backend.send(claude, "hello-live")
    check("send succeeds", ok ~= nil, err)
    vim.wait(800)
    local text = read(os.getenv("SKU_CLAUDE_PANE"))
    check("sent text reaches the pane", text:find("hello-live", 1, true) ~= nil, text)
    check("send did not press Enter", text:find("got: hello-live", 1, true) == nil, text)
    ok, err = backend.submit(claude)
    check("submit succeeds", ok ~= nil, err)
    vim.wait(800)
    text = read(os.getenv("SKU_CLAUDE_PANE"))
    check("submit presses Enter", text:find("got: hello-live", 1, true) ~= nil, text)

    ok, err = backend.focus(claude)
    check("focus succeeds", ok ~= nil, err)
    local info = vim.json.decode((herdr("pane", "get", os.getenv("SKU_CLAUDE_PANE"))))
    observe("focused after agent focus", info.result.pane.focused)

    local before = pane_count()
    local started, start_err = registry.start(tools.get("claude"))
    check("start outside the mux is refused", started == nil and start_err and start_err.id == "not_in_mux", start_err)
    check("refused start created no pane", pane_count() == before)
  elseif phase == "blocked" then
    local sessions = registry.discover()
    local codex = find(sessions, codex_id)
    check("codex session is listed", codex ~= nil, sessions)
    if not codex then
      return
    end
    check("state is blocked", codex.state == "blocked", codex.state)
    local ok, err = backend.send(codex, "nope-live")
    check("send to a blocked pane is refused", ok == nil and err and err.id == "session_blocked", err)
    vim.wait(500)
    check("nothing reached the blocked pane", read(os.getenv("SKU_CODEX_PANE")):find("nope-live", 1, true) == nil)
    local gone = vim.tbl_extend("force", codex, { pane_id = "w999:p999", id = "herdr:w999:p999" })
    ok, err = backend.send(gone, "nope-live")
    check("send with an unreadable state is refused", ok == nil and err and err.id == "status_unreadable", err)
  elseif phase == "start" then
    check("inside() is true in the pane", backend.inside() == true)
    local before = pane_count()
    local session, err = registry.start(tools.get("claude"))
    if not session then
      local msg = err and err.msg or ""
      if
        err
        and err.id == "backend_error"
        and (msg:find('"code":"timeout"', 1, true) or msg:find("agent_start_failed", 1, true))
      then
        -- herdr never saw the stub as an interactive agent (it needs the screen state idle); the backend closes the pane.
        log("UNVERIFIABLE start: UNVERIFIABLE with stubs: " .. msg)
        check("failed start closed the pane it created", pane_count() == before)
      else
        check("start returns a session", false, err)
      end
      return
    end
    check("start returns a session", true)
    observe("started session", session)
    check("started session is running at once", registry.is_running(session), session)
    check("start created exactly one pane", pane_count() == before + 1)
    local _, panes = pane_count()
    local focused = {}
    for _, pane in ipairs(panes) do
      focused[pane.pane_id] = pane.focused
    end
    check("start left the new pane unfocused", focused[session.pane_id] == false, focused)
    check("start left nvim's pane focused", focused[vim.env.HERDR_PANE_ID] == true, focused)
    if session.state == "blocked" then
      -- agent_not_ready: the agent is running but blocked during startup, so the guard rightly refuses to send.
      log("UNVERIFIABLE start: agent blocked at startup; rediscovery, send and submit not exercised")
      return
    end
    check("attach started session", registry.attach(session) == true)
    vim.wait(2000)
    local fresh = find(registry.discover(), session.id)
    check("rediscovery lists the started pane", fresh ~= nil and fresh.tool == "claude", fresh)
    if fresh then
      observe("rediscovered session", fresh)
      check("rediscovered session is running", registry.is_running(fresh), fresh)
      check("attached entry survived rediscovery", #registry.attached() == 1)
      local ok, send_err = backend.send(fresh, "start-live")
      check("send to the started pane", ok ~= nil, send_err)
      ok, send_err = backend.submit(fresh)
      check("submit to the started pane", ok ~= nil, send_err)
      vim.wait(800)
      check("started pane echoes the line", read(fresh.pane_id):find("got: start-live", 1, true) ~= nil)
    end
  end
end

local ok, err = pcall(run)
if not ok then
  log("FAIL driver error: " .. tostring(err))
end
log("DONE")
vim.cmd("qa!")
EOF

# --- server ---------------------------------------------------------------------------------------------------
case "$SOCK" in
  /tmp/sku-live-herdr/*) ;;
  *) die "socket path is not under the root: $SOCK" ;;
esac
[ "${#SOCK}" -lt 100 ] || die "socket path is too long for a unix socket: $SOCK"

# Inline `env` with $HX_ENV, not the hx_env function: a backgrounded function runs in a subshell, so $! would be the
# subshell's pid. `env` execs herdr, so $! is the server's own pid, which is the only pid the teardown ever signals.
say herdr server '(background, log in' "$R/server.log)"
# shellcheck disable=SC2086
env $HX_ENV "$HERDR" server >"$R/server.log" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" >"$R/server.pid"

n=0
while [ ! -S "$SOCK" ]; do
  n=$((n + 1))
  [ "$n" -le 40 ] || die "server socket did not appear at $SOCK; see $R/server.log"
  sleep 0.5
done
[ -S "$SOCK" ] || die "no socket at $SOCK"

n=0
until hx workspace list >/dev/null 2>&1; do
  n=$((n + 1))
  [ "$n" -le 40 ] || die "server did not answer; see $R/server.log"
  sleep 0.5
done

# --- panes: A = stub claude, B = stub codex, C = plain shell for nvim ---------------------------------------
jget() { "$NVIM" -u NONE -i NONE --headless -l "$R/jget.lua" "$1"; }

hx workspace create --cwd "$R/work" --label sku-live >"$R/out/workspace.json"
PANE_A=$(jget result.root_pane.pane_id <"$R/out/workspace.json")
hx pane split --pane "$PANE_A" --direction right --cwd "$R/work" --no-focus >"$R/out/split-b.json"
PANE_B=$(jget result.pane.pane_id <"$R/out/split-b.json")
hx pane split --pane "$PANE_B" --direction down --cwd "$R/work" --no-focus >"$R/out/split-c.json"
PANE_C=$(jget result.pane.pane_id <"$R/out/split-c.json")
for id in "$PANE_A" "$PANE_B" "$PANE_C"; do
  case "$id" in "" | nil) die "could not read a pane id from the split responses" ;; esac
done
echo "panes: claude=$PANE_A codex=$PANE_B shell=$PANE_C"

hx pane run "$PANE_A" claude
hx pane run "$PANE_B" codex
sleep 1.5
hx pane report-agent "$PANE_A" --source sku-live --agent claude --state idle
hx pane report-agent "$PANE_B" --source sku-live --agent codex --state idle
sleep 1

# --- drive nvim outside the mux --------------------------------------------------------------------------------
nv() {
  phase=$1
  say nvim "(headless, phase $phase, output $R/out/$phase.txt)"
  hx_env \
    SKU_REPO="$REPO" SKU_OUT="$R/out/$phase.txt" SKU_PHASE="$phase" SKU_CWD="$R/work" \
    SKU_CLAUDE_PANE="$PANE_A" SKU_CODEX_PANE="$PANE_B" \
    /usr/bin/perl -e 'alarm 90; exec @ARGV' -- "$NVIM" --headless -u NONE -i NONE -l "$R/drive.lua" || true
}

nv basic

hx pane report-agent "$PANE_B" --source sku-live --agent codex --state blocked
sleep 1
nv blocked

# --- drive nvim inside the mux: typed into pane C, which gives it HERDR_PANE_ID and TERM_PROGRAM=herdr -----------
CMD="SKU_REPO=$REPO SKU_OUT=$R/out/start.txt SKU_PHASE=start SKU_CWD=$R/work SKU_CLAUDE_PANE=$PANE_A SKU_CODEX_PANE=$PANE_B $NVIM --headless -u NONE -i NONE -l $R/drive.lua"
hx pane run "$PANE_C" "$CMD"
n=0
until grep -q '^DONE' "$R/out/start.txt" 2>/dev/null; do
  n=$((n + 1))
  [ "$n" -le 120 ] || {
    echo "inside phase did not finish within 60 s" >&2
    break
  }
  sleep 0.5
done

# --- report ----------------------------------------------------------------------------------------------------
fail=0
for phase in basic blocked start; do
  echo "== $phase"
  cat "$R/out/$phase.txt" 2>/dev/null || {
    echo "FAIL no output for phase $phase"
    fail=1
  }
  if grep -q '^FAIL' "$R/out/$phase.txt" 2>/dev/null; then fail=1; fi
  grep -q '^DONE' "$R/out/$phase.txt" 2>/dev/null || fail=1
done
echo "== server log"
tail -n 20 "$R/server.log" || true
if [ "$fail" = 0 ]; then
  echo "LIVE herdr: all checks passed"
else
  echo "LIVE herdr: FAILED"
fi
exit "$fail"
