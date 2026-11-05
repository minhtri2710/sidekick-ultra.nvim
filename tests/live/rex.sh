#!/usr/bin/env bash
# DRAFT for delivery 3. Live run of the rex backend against a private rex server, with stub agent CLIs only.
# Do not run it before the Supervisor has checked this recipe. Refuses unless SKU_LIVE=1.
#
# Everything lives under the literal root /tmp/sku-live-rex: HOME, XDG dirs, the server socket, state and stubs.
# The script refuses when that root already exists. It starts a private server as a background job, creates two
# sessions on it (stub agents; headless nvim with the plugin inside a block), lets nvim discover, attach, send,
# submit, focus and start, then checks the stubs' terminal output. Every rex call passes `--autostart=false` and
# `-S unix:///tmp/sku-live-rex/rex.sock`; none relies on REX_SERVER and none touches the default socket.
# Teardown: the server's own stop call, a signal to the recorded server pid only, then rm -rf of the literal root.
#
# Needs: jq, nvim, and the rex CLI from the Rex Beta bundle (override with SKU_REX_BIN).
# What it settles (unverified until it runs): the `split` and `focus` commands and flags, the shapes of `ls`,
# `session.view`, `process`, `program_status` and the `split --json` reply, argv0 reporting for a re-exec'd stub,
# and whether a block started with a bare command name finds it on the server's PATH.
set -eu
set -o pipefail

ROOT=/tmp/sku-live-rex
SOCK_PATH=$ROOT/rex.sock
SOCK=unix://$SOCK_PATH
REX=${SKU_REX_BIN:-/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex}
PLUGIN=$(cd "$(dirname "$0")/../.." && pwd -P)

say() { # print a command before it runs
  printf '+' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

x() { # print, then run
  say "$@"
  "$@"
}

# One rex client call against the private server, with the rex variables of any enclosing rex removed.
rexc() {
  set -- env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u TERM_PROGRAM HOME="$ROOT/home" \
    "$REX" --autostart=false -S "$SOCK" "$@"
  say "$@"
  "$@"
}

if [ "${SKU_LIVE:-}" != 1 ]; then
  echo "refusing: set SKU_LIVE=1 to run the live rex check" >&2
  exit 1
fi
if [ -e "$ROOT" ]; then
  echo "refusing: $ROOT already exists" >&2
  exit 1
fi
if [ ! -x "$REX" ]; then
  echo "refusing: rex CLI not executable: $REX" >&2
  exit 1
fi
NVIM=$(command -v nvim) || { echo "refusing: nvim not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "refusing: jq not found" >&2; exit 1; }

# Preflight: the socket must lie under the root.
case $SOCK_PATH in
  "$ROOT"/*) ;;
  *) echo "refusing: socket $SOCK_PATH is not under $ROOT" >&2; exit 1 ;;
esac

CREATED=0
SERVER_PID=
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$SERVER_PID" ]; then
    rexc api call server.stop || true
    sleep 1
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      x kill "$SERVER_PID" || true
    fi
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ "$CREATED" = 1 ]; then
    x rm -rf /tmp/sku-live-rex
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

x mkdir "$ROOT"
CREATED=1
x mkdir "$ROOT/home" "$ROOT/config" "$ROOT/data" "$ROOT/state" "$ROOT/cache" "$ROOT/bin" "$ROOT/work" "$ROOT/out"
: >"$ROOT/empty.lua"

# Stub agent CLIs: print a banner, echo every stdin line, exit on EOF. They re-exec bash under their own name so
# the process reports argv0 "<name>" the way the real CLIs do.
make_stub() {
  cat >"$ROOT/bin/$1" <<EOF
#!/bin/bash
if [ "\${SKU_STUB:-}" != "$1" ]; then
  SKU_STUB=$1 exec -a $1 /bin/bash "\$0" "\$@"
fi
echo "stub $1 ready"
while IFS= read -r line; do
  echo "got: \$line"
done
EOF
  chmod 755 "$ROOT/bin/$1"
}
make_stub claude
make_stub codex

# Private server, background job with its pid recorded.
say env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u TERM_PROGRAM \
  HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/config" XDG_DATA_HOME="$ROOT/data" XDG_STATE_HOME="$ROOT/state" \
  XDG_CACHE_HOME="$ROOT/cache" PATH="$ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$REX" --autostart=false server run --listen "$SOCK" --state-dir "$ROOT/state" --config "$ROOT/empty.lua" --exit-empty
env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u TERM_PROGRAM \
  HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/config" XDG_DATA_HOME="$ROOT/data" XDG_STATE_HOME="$ROOT/state" \
  XDG_CACHE_HOME="$ROOT/cache" PATH="$ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$REX" --autostart=false server run --listen "$SOCK" --state-dir "$ROOT/state" --config "$ROOT/empty.lua" --exit-empty \
  >"$ROOT/server.log" 2>&1 &
SERVER_PID=$!
echo "server pid $SERVER_PID"

# Readiness probe, then the preflight that the CLI really talks to the private socket.
ready=0
for _ in $(seq 1 50); do
  if rexc api call server.status >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
if [ "$ready" != 1 ]; then
  echo "server did not become ready; log:" >&2
  cat "$ROOT/server.log" >&2
  exit 1
fi
whoami=$(rexc whoami --json)
case $whoami in
  *"$SOCK_PATH"*) ;;
  *) echo "refusing: whoami does not name $SOCK_PATH: $whoami" >&2; exit 1 ;;
esac

# Sessions: the stub agents in one, headless nvim with the plugin in a block of another.
created=$(rexc new live-agents -c "$ROOT/work" --window claude --json -- "$ROOT/bin/claude")
AGENTS_SID=$(printf '%s' "$created" | jq -er '.session_id')
CLAUDE_BLOCK=$(printf '%s' "$created" | jq -er '.initial_windows[0].block_ids[0]')
created=$(rexc window new -s "$AGENTS_SID" codex -c "$ROOT/work" --focus=false --json -- "$ROOT/bin/codex")
CODEX_BLOCK=$(printf '%s' "$created" | jq -er '.block_ids[0]')

# The driver runs inside a rex block, so TERM_PROGRAM, REX_SESSION and REX_BLOCK are set for `inside()` and `start`.
cat >"$ROOT/driver.lua" <<EOF
local ROOT, REX, SOCK, PLUGIN = [==[$ROOT]==], [==[$REX]==], [==[$SOCK]==], [==[$PLUGIN]==]
EOF
cat >>"$ROOT/driver.lua" <<'EOF'
local logf = assert(io.open(ROOT .. "/out/driver.log", "w"))
local function log(...)
  logf:write(string.format(...), "\n")
  logf:flush()
end
local function step(label, res, err)
  log("%s: %s%s", label, res and "ok" or "error", err and (" " .. err.id .. " " .. err.msg) or "")
  return res
end

local function main()
  vim.opt.runtimepath:prepend(PLUGIN)
  require("sidekick-ultra").setup({
    herdr = { enabled = false },
    rex = { bin = REX, server = SOCK },
    tools = { claude = { cmd = { ROOT .. "/bin/claude" } }, codex = { cmd = { ROOT .. "/bin/codex" } } },
  })
  local registry = require("sidekick-ultra.registry")
  local rex = assert(registry.backend("rex"), "rex backend not registered")
  log("inside=%s", tostring(rex.inside()))

  local by_tool = {}
  for _, s in ipairs(registry.discover()) do
    log("discovered %s tool=%s cwd=%s pid=%d proc=%s", s.id, s.tool, s.cwd, s.pid, s.proc_name)
    by_tool[s.tool] = by_tool[s.tool] or s
  end
  local claude = assert(by_tool.claude, "claude block not discovered")
  step("attach", registry.attach(claude))
  step("send", rex.send(claude, "hello from sku\n"))
  vim.wait(300)
  step("submit", rex.submit(claude))
  vim.wait(300)
  step("focus", rex.focus(claude))

  local started, err = registry.start(require("sidekick-ultra.tools").get("codex"))
  if step("start", started, err) then
    log("started %s sid=%s block=%s cwd=%s", started.id, started.session_id, started.block_id, started.cwd)
    local f = assert(io.open(ROOT .. "/out/started", "w"))
    f:write(started.session_id, "\n", started.block_id, "\n")
    f:close()
    registry.attach(started)
    vim.wait(300)
    step("send2", rex.send(started, "second line\n"))
    vim.wait(300)
    step("submit2", rex.submit(started))
  end
  vim.wait(500)
end

local ok, e = pcall(main)
if not ok then
  log("driver error: %s", tostring(e))
end
io.open(ROOT .. "/out/done", "w"):close()
EOF
cat >"$ROOT/run-nvim.sh" <<EOF
#!/bin/sh
exec "$NVIM" --headless -u NONE -i NONE -l "$ROOT/driver.lua" >"$ROOT/out/nvim.log" 2>&1
EOF
chmod 755 "$ROOT/run-nvim.sh"
rexc new live-nvim -c "$ROOT/work" --window nvim --json -- "$ROOT/run-nvim.sh" >/dev/null

for _ in $(seq 1 100); do
  [ -e "$ROOT/out/done" ] && break
  sleep 0.5
done
[ -e "$ROOT/out/done" ] || { echo "driver did not finish" >&2; cat "$ROOT/out/nvim.log" >&2 || true; exit 1; }

echo "---- driver log"
cat "$ROOT/out/driver.log"
echo "---- nvim log"
cat "$ROOT/out/nvim.log" || true

# Evidence: raw shapes, to compare against tests/fixtures/rex.
echo "---- evidence: ls --json"
rexc ls --json
echo "---- evidence: session.view (agents)"
rexc api call -s "$AGENTS_SID" session.view
echo "---- evidence: process (claude block)"
rexc block call -s "$AGENTS_SID" -b "$CLAUDE_BLOCK" process
echo "---- evidence: program_status (claude block)"
rexc block call -s "$AGENTS_SID" -b "$CLAUDE_BLOCK" program_status
echo "---- evidence: session inspect (focus result)"
rexc session inspect "$AGENTS_SID" --json
echo "---- evidence: help text"
rexc split --help
rexc focus --help

claude_screen=$(rexc capture -s "$AGENTS_SID" -b "$CLAUDE_BLOCK" --trim)
started_sid=$(sed -n 1p "$ROOT/out/started" 2>/dev/null || true)
started_block=$(sed -n 2p "$ROOT/out/started" 2>/dev/null || true)
started_screen=
if [ -n "$started_block" ]; then
  started_screen=$(rexc capture -s "$started_sid" -b "$started_block" --trim)
fi
echo "---- claude block screen"
printf '%s\n' "$claude_screen"
echo "---- started block screen"
printf '%s\n' "$started_screen"

FAILS=0
check() { # name, then a command that succeeds when the check holds
  name=$1
  shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    FAILS=$((FAILS + 1))
  fi
}
log_has() { grep -qF -- "$1" "$ROOT/out/driver.log"; }
screen_has() { printf '%s' "$1" | grep -qF -- "$2"; }

check "inside() true in the nvim block" log_has "inside=true"
check "discover lists the claude block" log_has "discovered rex:$CLAUDE_BLOCK tool=claude"
check "discover lists the codex block" log_has "discovered rex:$CODEX_BLOCK tool=codex"
check "attach" log_has "attach: ok"
check "send" log_has "send: ok"
check "submit" log_has "submit: ok"
check "focus" log_has "focus: ok"
check "start" log_has "start: ok"
check "send2" log_has "send2: ok"
check "submit2" log_has "submit2: ok"
check "text reached the claude stub" screen_has "$claude_screen" "got: hello from sku"
check "started block runs the codex stub" screen_has "$started_screen" "stub codex ready"
check "text reached the started stub" screen_has "$started_screen" "got: second line"

if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
EOF
