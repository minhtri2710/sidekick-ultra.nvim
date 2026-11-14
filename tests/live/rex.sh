#!/usr/bin/env bash
# Live run of the rex backend against a private rex server, with stub agent CLIs only. Not part of `make check`.
# Refuses unless SKU_LIVE=1.
#
# Everything lives under the literal root /tmp/sku-live-rex: HOME, XDG dirs, the server socket, state and stubs.
# The script refuses when that root already exists. It starts a private server as a background job, creates two
# sessions on it (stub agents; headless nvim with the plugin inside a block), lets nvim discover, attach, send,
# submit, focus and start, then checks the stubs' terminal output. Every rex call passes `--autostart=false` and
# `-S unix:///tmp/sku-live-rex/rex.sock`; none relies on REX_SERVER and none touches the default socket.
# Teardown: the server's own stop call, a signal to the recorded server pid only, then rm -rf of the literal root.
#
# Probes (answers for the record, each printed as `EVIDENCE <item>: ...`):
#   before the server starts: `--help` of rex, `server run`, `split` and, when the root help lists it, `program-status` or
#     `status`, all through rexc; the run aborts unless the help shows --autostart, -S (or --server), --listen,
#     --state-dir, --exit-empty and --config;
#   HL5: the raw `split --json` answer, the session listing and the new block's `process` right after it (no delay), for
#     the plugin's starts and two direct splits: is there a cwd;
#   HL13: a second block the plugin starts, whose stub exits on a `quit` line. `quit` and Enter are typed with the raw
#     CLI, then nothing is sent or submitted to that block: rex runs it through a login shell that may outlive the stub.
#     The block's `process`, `program_status`, recorded pid and the plugin's liveness answer are printed before and after.
# The binary is printed with its sha256 before the first exec and again at the end. SKU_REX_SHA256, when set, is the
# expected hash: a mismatch refuses before any exec. A hash that changed during the run prints `EVIDENCE MIXED`.
#
# Needs: jq, nvim, and the rex CLI from the Rex Beta bundle (override with SKU_REX_BIN).
# What it checks: the `split` and `focus` commands and flags, the shapes of `ls`,
# `session.view`, `process`, `program_status` and the `split --json` reply, argv0 reporting for a re-exec'd stub,
# whether a block started with a bare command name finds it on the server's PATH, and that `send` types text without
# pressing Enter (the driver captures each screen between send and submit).
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

# The one environment the private server and every rex client call run in: an allowlist, `env -i` plus explicit
# assignments. A `-u` blocklist can never be complete (REX_*, ENV, BASH_ENV, PROMPT_COMMAND, exported bash functions and
# names we do not know would get through). The PATH has the stubs first and no host bin dir.
ISO_PATH=$ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin
USER_NAME=$(id -un)
ISO_ENV=(env -i
  HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/config" XDG_DATA_HOME="$ROOT/data" XDG_STATE_HOME="$ROOT/state"
  XDG_CACHE_HOME="$ROOT/cache" PATH="$ISO_PATH" USER="$USER_NAME" LOGNAME="$USER_NAME" TMPDIR="$ROOT/tmp"
  LANG=en_US.UTF-8 TERM=xterm-256color SHELL=/bin/sh)

# One rex client call against the private server.
rexc() {
  set -- "${ISO_ENV[@]}" "$REX" --autostart=false -S "$SOCK" "$@"
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
# The binary's identity, printed and checked before anything runs it.
REX_SHA=$(/usr/bin/shasum -a 256 "$REX" | cut -d' ' -f1)
[ -n "$REX_SHA" ] || { echo "refusing: cannot hash $REX" >&2; exit 1; }
echo "rex binary: $REX sha256 $REX_SHA"
if [ -n "${SKU_REX_SHA256:-}" ] && [ "$SKU_REX_SHA256" != "$REX_SHA" ]; then
  echo "refusing: rex sha256 is $REX_SHA, the recipe expects $SKU_REX_SHA256" >&2
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
x mkdir "$ROOT/home" "$ROOT/config" "$ROOT/data" "$ROOT/state" "$ROOT/cache" "$ROOT/tmp" "$ROOT/bin" "$ROOT/work" "$ROOT/out"
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
  if [ "\$line" = quit ]; then
    echo "stub $1 quitting"
    exit 7
  fi
  echo "got: \$line"
done
EOF
  chmod 755 "$ROOT/bin/$1"
}
# A line `quit` ends the stub with exit code 7. Only HL13 types it, and only into the block of `quitter`.
make_stub claude
make_stub codex
make_stub quitter

# Refuse unless the stubs exist: claude and codex must be regular executable files, written above, at the absolute paths
# $ROOT/bin/claude and $ROOT/bin/codex. rex runs block commands through the user's login shell, which gets the ISO_ENV
# variables and nothing else from us, but its startup files can still change PATH, so PATH is not relied on: every
# block command in this script is an absolute path ($ROOT/bin/claude, $ROOT/bin/codex, $ROOT/run-nvim.sh, which execs
# the absolute $NVIM). The PATH lookup below only proves that ISO_PATH, which the server and the clients get, finds the
# stubs first. Nothing is executed.
for name in claude codex; do
  found=$(
    PATH=$ISO_PATH
    command -v "$name"
  ) || found=
  if [ "$found" != "$ROOT/bin/$name" ] || [ -L "$ROOT/bin/$name" ] || [ ! -f "$ROOT/bin/$name" ] || [ ! -x "$ROOT/bin/$name" ]; then
    echo "refusing: $name resolves to '$found' under PATH=$ISO_PATH, not to the stub $ROOT/bin/$name" >&2
    exit 2
  fi
done

# Help preflight: `--help` is a run of rex, so it goes through rexc (env -i allowlist, --autostart=false, -S root socket).
# Residual risk: the first call, the root `--help`, runs before any help has shown that --autostart and -S exist. It
# carries both flags and asks only for help; the rest of the run starts only after the help shows every flag it needs.
# rexc prints its own `+ ...` line to stderr first; that line names the flags, so it is cut from the saved help text.
HELP_FILES=()
help_of() { # <rex words...>: print and keep the help of `rex <words> --help`
  local n=${#HELP_FILES[@]} rc=0
  local out="$ROOT/out/help-$n.txt"
  rexc "$@" --help >"$out.stdout" 2>"$out.stderr" || rc=$?
  head -n 1 "$out.stderr" >&2
  { cat "$out.stdout"; tail -n +2 "$out.stderr"; } >"$out"
  echo "---- help: rex $* --help (exit $rc)"
  cat "$out"
  [ "$rc" = 0 ] || { echo "refusing: rex $* --help exited $rc" >&2; exit 1; }
  HELP_FILES+=("$out")
}
help_of
help_of server run
help_of split
# HL13's second half: a subcommand for the program status, when the root help lists one.
for sub in program-status status; do
  if grep -qE "^[[:space:]]+$sub([[:space:]]|\$)" "${HELP_FILES[0]}"; then
    help_of "$sub"
  fi
done
cat "${HELP_FILES[@]}" >"$ROOT/out/help-all.txt"
for flag in --autostart --listen --state-dir --exit-empty --config; do
  grep -qE -- "(^|[^[:alnum:]-])$flag([^[:alnum:]-]|\$)" "$ROOT/out/help-all.txt" ||
    { echo "refusing: the help does not show $flag" >&2; exit 1; }
done
grep -qE -e '(^|[^[:alnum:]-])-S([^[:alnum:]-]|$)' -e '(^|[^[:alnum:]-])--server([^[:alnum:]-]|$)' "$ROOT/out/help-all.txt" ||
  { echo "refusing: the help does not show -S or --server" >&2; exit 1; }

# Private server, background job with its pid recorded.
# `env` execs rex, so $! is the server's own pid.
say "${ISO_ENV[@]}" \
  "$REX" --autostart=false server run --listen "$SOCK" --state-dir "$ROOT/state" --config "$ROOT/empty.lua" --exit-empty
"${ISO_ENV[@]}" \
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

---Run one rex client call now and write its stdout to out/<name> (empty on failure). The shell cannot read a screen
---between send and submit, or a view while nvim's block is still open, so the driver takes them.
local function save(name, ...)
  local res = vim.system({ REX, "--autostart=false", "-S", SOCK, ... }, { text = true }):wait()
  local f = assert(io.open(ROOT .. "/out/" .. name, "w"))
  f:write(res.code == 0 and res.stdout or "")
  f:close()
  log("%s: exit %d", name, res.code)
end

---One read-only or raw rex client call now: its stdout and exit code. The same flags as `save`, never the plugin.
local function raw(...)
  local res = vim.system({ REX, "--autostart=false", "-S", SOCK, ... }, { text = true }):wait()
  return res.stdout or "", res.code
end
local function decode(text)
  local ok, value = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return ok and value or nil
end
---Whether any key named cwd, anywhere in the value, holds a non-empty string.
local function has_cwd(value)
  if type(value) ~= "table" then
    return false
  end
  for key, child in pairs(value) do
    if (key == "cwd" and type(child) == "string" and child ~= "") or has_cwd(child) then
      return true
    end
  end
  return false
end

---HL5: the raw `split --json` answer of a block, the session listing and the new block's `process` taken at once
---after it (no delay), and whether each has a cwd. The plugin takes a started block's cwd from `process`.
local function hl5(label, sid, split_out)
  log("EVIDENCE HL5: %s split --json raw: %s", label, split_out)
  local answer = decode(split_out)
  log("EVIDENCE HL5: %s split answer cwd %s", label, has_cwd(answer) and "present" or "absent")
  log("EVIDENCE HL5: %s session listing right after: %s", label, (raw("ls", "--json")))
  local ids = type(answer) == "table" and answer.block_ids
  local bid = type(ids) == "table" and ids[1]
  if type(bid) ~= "string" then
    log("EVIDENCE HL5: %s cwd absent (no block id in the split answer, no process read)", label)
    return
  end
  local process = raw("block", "call", "-s", sid, "-b", bid, "process")
  log("EVIDENCE HL5: %s process right after: %s", label, process)
  log("EVIDENCE HL5: %s process cwd %s", label, has_cwd(decode(process)) and "present" or "absent")
end

local function main()
  vim.opt.runtimepath:prepend(PLUGIN)
  require("sidekick-ultra").setup({
    herdr = { enabled = false },
    tmux = { enabled = false },
    zellij = { enabled = false },
    rex = { bin = REX, server = SOCK },
    tools = { claude = { cmd = { ROOT .. "/bin/claude" } }, codex = { cmd = { ROOT .. "/bin/codex" } } },
  })
  local registry = require("sidekick-ultra.registry")
  local rex = assert(registry.backend("rex"), "rex backend not registered")
  log("inside=%s", tostring(rex.inside()))

  -- HL5, observation only: after each `split` the plugin runs, log the raw answer and what rex shows at once.
  local exec = require("sidekick-ultra.exec")
  local run = exec.run
  exec.run = function(argv, opts)
    local res, run_err = run(argv, opts)
    if argv[5] == "split" then
      hl5("plugin start", vim.env.REX_SESSION, res and res.stdout or "")
    end
    return res, run_err
  end

  local by_tool = {}
  for _, s in ipairs(registry.discover()) do
    log("discovered %s tool=%s cwd=%s pid=%d proc=%s", s.id, s.tool, s.cwd, s.pid, s.proc_name)
    by_tool[s.tool] = by_tool[s.tool] or s
  end
  local claude = assert(by_tool.claude, "claude block not discovered")
  step("attach", registry.attach(claude))
  step("send", rex.send(claude, "hello from sku"))
  vim.wait(500)
  save("claude_after_send", "capture", "-s", claude.session_id, "-b", claude.block_id, "--trim")
  step("submit", rex.submit(claude))
  vim.wait(300)
  step("focus", rex.focus(claude))

  local started, err = registry.start(require("sidekick-ultra.tools").get("codex"))
  if step("start", started, err) then
    log("started %s sid=%s block=%s cwd=%s", started.id, started.session_id, started.block_id, started.cwd)
    local f = assert(io.open(ROOT .. "/out/started", "w"))
    f:write(started.session_id, "\n", started.block_id, "\n")
    f:close()
    save("split_view", "api", "call", "-s", started.session_id, "session.view")
    registry.attach(started)
    vim.wait(300)
    step("send2", rex.send(started, "second line"))
    vim.wait(500)
    save("started_after_send", "capture", "-s", started.session_id, "-b", started.block_id, "--trim")
    step("submit2", rex.submit(started))
  end
  vim.wait(500)

  -- HL13: a second block the plugin starts, running the stub that exits on `quit`. After quit nothing goes to it through
  -- the plugin: no send, no submit (its login shell may still be alive and would run what is typed).
  local quit_tool =
    vim.tbl_extend("force", require("sidekick-ultra.tools").get("codex"), { cmd = { ROOT .. "/bin/quitter" } })
  local quitter, quit_err = registry.start(quit_tool)
  step("start3", quitter, quit_err)
  if quitter then
    local proc = require("sidekick-ultra.proc")
    local function snap(label)
      local process = raw("block", "call", "-s", quitter.session_id, "-b", quitter.block_id, "process")
      local status = raw("block", "call", "-s", quitter.session_id, "-b", quitter.block_id, "program_status")
      log("EVIDENCE HL13: %s process: %s", label, process)
      log("EVIDENCE HL13: %s program_status: %s", label, status)
      local running = registry.is_running(quitter)
      log(
        "EVIDENCE HL13: %s recorded pid=%s proc_name=%s, proc.name(pid)=%s, registry.is_running=%s, backend is_running=%s",
        label,
        quitter.pid,
        quitter.proc_name,
        tostring(proc.name(quitter.pid)),
        tostring(running),
        tostring(rex.is_running)
      )
      return decode(process), running
    end
    snap("before quit")
    local out, code = raw("send", "-s", quitter.session_id, "-b", quitter.block_id, "--", "quit")
    log("EVIDENCE HL13: raw send quit: exit %d %s", code, out)
    out, code = raw("send-key", "-s", quitter.session_id, "-b", quitter.block_id, "enter")
    log("EVIDENCE HL13: raw send-key enter: exit %d %s", code, out)
    vim.wait(1500)
    local process, running = snap("after quit")
    local function describe(entry)
      return type(entry) == "table"
          and ("%s (pid %s, argv0 %s)"):format(tostring(entry.name), tostring(entry.pid), tostring(entry.argv0))
        or "none"
    end
    local last_exit = type(process) == "table" and process.last_exit ~= nil and vim.json.encode(process.last_exit) or "none"
    log(
      "EVIDENCE HL13: after quit foreground=%s, child=%s, last_exit=%s, is_running=%s",
      describe(type(process) == "table" and process.foreground or nil),
      describe(type(process) == "table" and process.child or nil),
      last_exit,
      tostring(running)
    )
    vim.wait(3000)
    snap("after quit +3 s")
    log("EVIDENCE HL13: session listing after quit: %s", (raw("ls", "--json")))
    log("EVIDENCE HL13: screen of the block after quit: %s", (raw("capture", "-s", quitter.session_id, "-b", quitter.block_id, "--trim")))
  end

  -- HL5: two direct splits of the codex block, with the raw CLI.
  local codex = by_tool.codex
  for i = 1, codex and 2 or 0 do
    local out = raw(
      "split", "-s", codex.session_id, "-b", codex.block_id, "--split=down", "-c", ROOT .. "/work",
      "--focus=false", "--json", "--", ROOT .. "/bin/codex"
    )
    hl5("direct split " .. i, codex.session_id, out)
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

for _ in $(seq 1 160); do
  [ -e "$ROOT/out/done" ] && break
  sleep 0.5
done
[ -e "$ROOT/out/done" ] || { echo "driver did not finish" >&2; cat "$ROOT/out/nvim.log" >&2 || true; exit 1; }

echo "---- driver log"
cat "$ROOT/out/driver.log"
echo "---- nvim log"
cat "$ROOT/out/nvim.log" || true

started_sid=$(sed -n 1p "$ROOT/out/started" 2>/dev/null || true)
started_block=$(sed -n 2p "$ROOT/out/started" 2>/dev/null || true)

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
echo "---- evidence: session.view (session that start split)"
cat "$ROOT/out/split_view" 2>/dev/null || true
echo "---- evidence: help text"
rexc split --help
rexc focus --help

claude_screen=$(rexc capture -s "$AGENTS_SID" -b "$CLAUDE_BLOCK" --trim)
started_screen=
if [ -n "$started_block" ]; then
  started_screen=$(rexc capture -s "$started_sid" -b "$started_block" --trim)
fi
claude_sent=$(cat "$ROOT/out/claude_after_send" 2>/dev/null || true)
started_sent=$(cat "$ROOT/out/started_after_send" 2>/dev/null || true)
echo "---- claude block screen after send, before submit"
printf '%s\n' "$claude_sent"
echo "---- claude block screen after submit"
printf '%s\n' "$claude_screen"
echo "---- started block screen after send, before submit"
printf '%s\n' "$started_sent"
echo "---- started block screen after submit"
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
# A bare `got:` line is an empty line the stub read: with `send` pressing Enter, `submit` sends a second, empty one.
no_empty_submit() { ! printf '%s\n' "$1" | grep -qx 'got:'; }
log_has() { grep -qF -- "$1" "$ROOT/out/driver.log"; }
screen_has() { printf '%s' "$1" | grep -qF -- "$2"; }
# The text is typed but not submitted: it is on the screen and the stub has not echoed it back as `got: <text>`.
# An empty capture fails the first half, so a failed capture cannot pass this.
unsubmitted() { screen_has "$1" "$2" && ! screen_has "$1" "got: $2"; }
# The window that holds the started block has another block focused, not this one. A missing view or block, and a
# window with no focused block (null), fail.
started_block_unfocused() {
  jq -e --arg b "$started_block" \
    '[.windows[] | select(any(.layers[].blocks[]; .block_id == $b)) | (.focused_block_id | type == "string") and .focused_block_id != $b] == [true]' \
    "$ROOT/out/split_view" >/dev/null
}

check "inside() true in the nvim block" log_has "inside=true"
check "discover lists the claude block" log_has "discovered rex:$CLAUDE_BLOCK tool=claude"
check "discover lists the codex block" log_has "discovered rex:$CODEX_BLOCK tool=codex"
check "attach" log_has "attach: ok"
check "send" log_has "send: ok"
check "claude screen was captured before submit" log_has "claude_after_send: exit 0"
check "send did not press Enter in the claude block" unsubmitted "$claude_sent" "hello from sku"
check "submit" log_has "submit: ok"
check "focus" log_has "focus: ok"
check "start" log_has "start: ok"
check "start of the HL13 block" log_has "start3: ok"
check "start left the started block unfocused" started_block_unfocused
check "send2" log_has "send2: ok"
check "started screen was captured before submit" log_has "started_after_send: exit 0"
check "send did not press Enter in the started block" unsubmitted "$started_sent" "second line"
check "submit2" log_has "submit2: ok"
check "submit sent the line once in the claude block" no_empty_submit "$claude_screen"
check "submit sent the line once in the started block" no_empty_submit "$started_screen"
check "text reached the claude stub" screen_has "$claude_screen" "got: hello from sku"
check "started block runs the codex stub" screen_has "$started_screen" "stub codex ready"
check "text reached the started stub" screen_has "$started_screen" "got: second line"

REX_SHA_END=$(/usr/bin/shasum -a 256 "$REX" | cut -d' ' -f1)
echo "rex binary at the end: $REX sha256 $REX_SHA_END"
if [ "$REX_SHA_END" != "$REX_SHA" ]; then
  echo "EVIDENCE MIXED: binary changed"
  FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
