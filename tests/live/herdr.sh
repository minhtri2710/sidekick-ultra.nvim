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
# Probes (answers for the record, not only checks; each prints `EVIDENCE <item>: ...`):
#   before the server starts: `--help` of herdr, `pane send-text`, `agent start`, `pane split` and `pane list`, all
#     through the isolated environment, then a check that the root socket still does not exist;
#   A9: the plugin sends `-- TODO` and `- @x` (dash-leading text) to the stub claude, then one direct `pane send-text --`;
#   A10: a direct `agent start --timeout 3000` of a stub that sleeps 6 s, and one of a ready stub, with wall times;
#   HL5: the raw JSON of every `agent start` (the plugin's inside the mux, the direct ones) and whether it has a cwd.
# The binary is printed with its sha256 before the first exec and again at the end. SKU_HERDR_SHA256, when set, is the
# expected hash: a mismatch refuses before any exec. A hash that changed during the run prints `EVIDENCE MIXED`.
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

# The binary's identity, printed and checked before anything runs it (shasum follows the symlink a package manager leaves).
sha_of() { /usr/bin/shasum -a 256 "$1" | cut -d' ' -f1; }
HERDR_SHA=$(sha_of "$HERDR")
[ -n "$HERDR_SHA" ] || die "cannot hash $HERDR"
echo "herdr binary: $HERDR sha256 $HERDR_SHA"
if [ -n "${SKU_HERDR_SHA256:-}" ] && [ "$SKU_HERDR_SHA256" != "$HERDR_SHA" ]; then
  die "herdr sha256 is $HERDR_SHA, the recipe expects $SKU_HERDR_SHA256"
fi

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
    keep=0
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
    elif [ -e "$SOCK" ]; then
      # A socket under the root while this run started no server: a command made one (a --help that autostarts), or
      # something else owns the path. We hold no pid for it, so stop it through the root socket and fail. The root
      # stays when the socket is still there afterwards: it is never removed over a server that may still answer.
      echo "FATAL collision: $SOCK exists but this run started no server" >&2
      status=1
      hx server stop || true
      sleep 2
      if [ -e "$SOCK" ]; then
        keep=1
        echo "FATAL collision: $SOCK is still there after server stop; $R is left in place, look before removing it" >&2
      fi
    fi
    if [ "$keep" = 0 ]; then
      say rm -rf /tmp/sku-live-herdr
      rm -rf /tmp/sku-live-herdr
    fi
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
  # An argument is a number of seconds to sleep before the title and the ready line (A10: a tool slow to become
  # interactive). The stub prints its arguments first, so the log shows whether herdr passed them.
  cat >"$R/bin/$1" <<EOF
#!/bin/bash
if [ "\${SKU_STUB:-}" != "$1" ]; then
  SKU_STUB=$1 exec -a $1 /bin/bash "\$0" "\$@"
fi
if [ "\$#" -gt 0 ]; then
  echo "SKU-STUB $1 args: \$*"
  sleep "\$1"
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
  elseif phase == "a9" then
    -- A9: text that starts with dashes goes through `herdr pane send-text <pane> <text>` with no `--`. The unsafe
    -- outcome is a send that returned ok while the stub's line is missing or different (herdr took the text as a flag).
    local claude = find(registry.discover(), claude_id)
    check("a9: the claude pane is listed", claude ~= nil)
    if not claude then
      return
    end
    local pane = os.getenv("SKU_CLAUDE_PANE")
    local function gots(text)
      local lines = {}
      for line in text:gmatch("[^\r\n]+") do
        line = vim.trim(line)
        if line:sub(1, 4) == "got:" then
          table.insert(lines, line)
        end
      end
      return lines
    end
    for _, text in ipairs({ "-- TODO", "- @x" }) do
      local seen = #gots(read(pane))
      local ok, err = backend.send(claude, text)
      vim.wait(800)
      if ok ~= nil then
        local sok, serr = backend.submit(claude)
        check("a9: submit after " .. text, sok ~= nil, serr)
        vim.wait(800)
      end
      local screen = read(pane)
      local new = vim.list_slice(gots(screen), seen + 1)
      local exact = vim.tbl_contains(new, "got: " .. text)
      log(
        ("EVIDENCE A9: send %s %s, stub got %s"):format(
          vim.inspect(text),
          ok ~= nil and "ok" or ("err " .. vim.inspect(err)),
          #new > 0 and vim.inspect(new) or "no new line"
        )
      )
      check("a9: send " .. text .. " is not ok with a missing or different line", ok == nil or exact, screen)
    end
  elseif phase == "start" then
    check("inside() is true in the pane", backend.inside() == true)
    -- HL5: log the raw answer of every `agent start` the plugin runs, and whether it carries a cwd. Observation only.
    local exec = require("sidekick-ultra.exec")
    local run = exec.run
    exec.run = function(argv, opts)
      local res, run_err = run(argv, opts)
      if argv[2] == "agent" and argv[3] == "start" then
        local body = res and res.stdout or ""
        local decoded_ok, decoded = exec.decode(body)
        local agent = decoded_ok and type(decoded) == "table" and type(decoded.result) == "table" and decoded.result.agent
        local has_cwd = type(agent) == "table"
          and (type(agent.cwd) == "string" or type(agent.foreground_cwd) == "string")
        log("EVIDENCE HL5: plugin agent start, exit " .. tostring(res and res.code) .. ", raw stdout: " .. body)
        log("EVIDENCE HL5: plugin agent start, stderr: " .. (res and res.stderr or vim.inspect(run_err)))
        log("EVIDENCE HL5: plugin agent start cwd " .. (has_cwd and "present" or "absent"))
      end
      return res, run_err
    end
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

# --- help preflight -------------------------------------------------------------------------------------------
case "$SOCK" in
  /tmp/sku-live-herdr/*) ;;
  *) die "socket path is not under the root: $SOCK" ;;
esac
[ "${#SOCK}" -lt 100 ] || die "socket path is too long for a unix socket: $SOCK"

# `--help` is a run of herdr, so it goes through hx, the isolated environment. Residual risk, as for any first call: the
# environment is what keeps a command that reaches for a server on the root socket and nowhere else.
help_of() { # <name> <herdr args...>: print and keep one help text
  name=$1
  shift
  say herdr "$@"
  hx_env "$HERDR" "$@" >"$R/out/help-$name.txt" 2>&1 || die "herdr $* failed; see $R/out/help-$name.txt"
  echo "---- help: herdr $*"
  cat "$R/out/help-$name.txt"
}
help_of root --help
help_of send-text pane send-text --help
help_of agent-start agent start --help
help_of split pane split --help
help_of list pane list --help
# A help call must not have started a server: no socket under the root yet (cleanup stops one that exists).
[ ! -e "$SOCK" ] || die "a help call left a socket at $SOCK"

# --- server ---------------------------------------------------------------------------------------------------

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

# --- probes, after the three phases above (A9, A10, HL5) -----------------------------------------------------
# A9, through the plugin from outside the mux; the stub claude pane is reported idle again so the send guard allows it.
hx pane report-agent "$PANE_A" --source sku-live --agent claude --state idle
sleep 1
nv a9

# A9, direct: one send-text with `--` before the text, as rex and zellij get it. Prints whether herdr accepted it.
say herdr pane send-text "$PANE_A" -- "-- TODO2"
rc=0
hx_env "$HERDR" pane send-text "$PANE_A" -- "-- TODO2" >"$R/out/a9-direct.out" 2>"$R/out/a9-direct.err" || rc=$?
if [ "$rc" = 0 ]; then
  hx pane send-keys "$PANE_A" Enter
  sleep 1
  got=$(hx pane read "$PANE_A" --source recent --lines 80 | grep -F 'got:' | tail -n 3)
  echo "EVIDENCE A9: direct send-text -- accepted (exit 0), stub got (last lines): $got"
else
  echo "EVIDENCE A9: direct send-text -- rejected (exit $rc), stderr: $(cat "$R/out/a9-direct.err")"
fi

now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
since() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.2f\n", time - $ARGV[0]' "$1"; }
has_value() { [ -n "$1" ] && [ "$1" != nil ] && [ "$1" != vim.NIL ]; }

# HL5 for one direct `agent start`: its raw stdout and whether the agent has a cwd.
hl5() { # <label> <stdout file>
  echo "EVIDENCE HL5: $1 raw stdout: $(cat "$2")"
  if [ ! -s "$2" ]; then
    echo "EVIDENCE HL5: $1 cwd n/a (no stdout)"
    return
  fi
  c=$(jget result.agent.cwd <"$2" 2>/dev/null) || c=
  f=$(jget result.agent.foreground_cwd <"$2" 2>/dev/null) || f=
  if has_value "$c" || has_value "$f"; then
    echo "EVIDENCE HL5: $1 cwd present"
  else
    echo "EVIDENCE HL5: $1 cwd absent"
  fi
}

# A10: a direct `agent start` on a pane of its own. Under a 60 s alarm of ours, whatever herdr does.
direct_start() { # <label> <timeout ms> <pane> <agent name> [words for the stub, after --]
  label=$1 tmo=$2 pane=$3 aname=$4
  shift 4
  if [ "$#" -gt 0 ]; then set -- -- "$@"; fi
  say herdr agent start "$aname" --kind claude --pane "$pane" --timeout "$tmo" "$@"
  t0=$(now)
  rc=0
  hx_env /usr/bin/perl -e 'alarm 60; exec @ARGV' -- "$HERDR" agent start "$aname" --kind claude --pane "$pane" --timeout "$tmo" "$@" \
    >"$R/out/start-$label.json" 2>"$R/out/start-$label.err" || rc=$?
  wall=$(since "$t0")
  code=$(jget error.code <"$R/out/start-$label.err" 2>/dev/null) || code="(none)"
  echo "EVIDENCE A10: $label agent start: wall $wall s, --timeout $tmo, exit $rc, stderr envelope code $code"
  echo "EVIDENCE A10: $label stderr: $(cat "$R/out/start-$label.err")"
  hl5 "$label" "$R/out/start-$label.json"
}

echo "EVIDENCE A10: help text about --timeout (units and range):"
grep -i -B1 -A2 -- 'timeout' "$R/out/help-agent-start.txt" || echo "EVIDENCE A10: the help of agent start mentions no timeout"

hx pane split --pane "$PANE_A" --direction down --cwd "$R/work" --no-focus >"$R/out/split-slow.json"
PANE_SLOW=$(jget result.pane.pane_id <"$R/out/split-slow.json")
hx pane split --pane "$PANE_A" --direction down --cwd "$R/work" --no-focus >"$R/out/split-fast.json"
PANE_FAST=$(jget result.pane.pane_id <"$R/out/split-fast.json")
for id in "$PANE_SLOW" "$PANE_FAST"; do
  case "$id" in "" | nil) die "could not read a pane id from the probe split responses" ;; esac
done

# The slow stub sleeps 6 s; herdr is asked to wait 3 s, its shortest accepted wait.
direct_start slow 3000 "$PANE_SLOW" sku-probe-slow 6
echo "EVIDENCE A10: slow pane get, right after:"
hx pane get "$PANE_SLOW" || true
echo "EVIDENCE A10: agent list, right after:"
hx agent list || true
sleep 6
echo "EVIDENCE A10: slow pane get, 6 s later:"
hx pane get "$PANE_SLOW" || true
echo "EVIDENCE A10: agent list, 6 s later:"
hx agent list || true
echo "EVIDENCE A10: slow pane screen, 6 s later:"
hx pane read "$PANE_SLOW" --source recent --lines 20 || true

# A ready stub, a long wait: does herdr return as soon as the agent is idle, or only when the wait ends?
direct_start fast 30000 "$PANE_FAST" sku-probe-fast

# --- report ----------------------------------------------------------------------------------------------------
fail=0
HERDR_SHA_END=$(sha_of "$HERDR")
echo "herdr binary at the end: $HERDR sha256 $HERDR_SHA_END"
if [ "$HERDR_SHA_END" != "$HERDR_SHA" ]; then
  echo "EVIDENCE MIXED: binary changed"
  fail=1
fi
for phase in basic blocked start a9; do
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
