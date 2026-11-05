#!/bin/sh
# DRAFT for D8. Live run of the zellij backend against a private zellij session and stub agent CLIs.
# Written, not run, by the D8 Engineer. The Lead sends this recipe to the Supervisor before the first run.
#
# What it does: creates a background zellij session under the literal root /tmp/sku-live-zellij (own HOME, XDG dirs,
# config dir, data dir and ZELLIJ_SOCKET_DIR), adds three stub-agent panes (claude, codex, and a claude that exits on
# `Q`), and drives headless nvim with the plugin:
#   outside the mux: discover, attach, send (no Enter), submit, focus, the gone-pane guard, the not_in_mux start refusal;
#   inside the mux (nvim typed into the session's first pane): inside(), discover, start through registry.start (the new
#                    pane is focused per D7, with a tool env), running at once, rediscovery, send, submit.
# Then it tears everything down: `kill-session` of the one session it made, and `rm -rf` of the root.
#
# It never lists or touches another session: every zellij call runs under `env -i` with ZELLIJ_SOCKET_DIR under the
# root, so the Human's sessions are not even visible. It never runs kill-all-sessions or delete-all-sessions.
set -eu

[ "${SKU_LIVE:-}" = 1 ] || {
  echo "refusing: set SKU_LIVE=1 to run the live zellij test" >&2
  exit 2
}

R=/tmp/sku-live-zellij
S=skulive
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
ZBIN=$(command -v zellij) || die "zellij is not on PATH"
NVIM=$(command -v nvim) || die "nvim is not on PATH"
case "$ZBIN" in */tests/bin/*) die "zellij resolves to a test stub: $ZBIN" ;; esac

[ -e "$R" ] && die "$R already exists; remove it yourself after looking at it"

CREATED=0

# The one PATH every pane, client and the server get: the stubs and zellij's symlink, then the system dirs. No host
# bin directory, so the real claude and codex CLIs are not reachable even if a stub goes missing.
ISO_PATH="$R/bin:/usr/bin:/bin"

# The one environment every zellij client, the server and the nvim driver run in, as `env` words: an allowlist, `env -i`
# plus explicit assignments. A `-u` blocklist can never be complete (ENV, BASH_ENV, PROMPT_COMMAND, exported bash
# functions and names we do not know would get through). Every value is a plain word (the root is a literal path, the
# user name comes from `id -un`), so none has a space or a glob character and the unquoted expansions below split
# correctly. ZELLIJ_SOCKET_DIR is what keeps the Human's sessions out of reach.
USER_NAME=$(id -un)
Z_ENV="-i HOME=$R/home TMPDIR=$R/tmp XDG_CONFIG_HOME=$R/xdg/config XDG_DATA_HOME=$R/xdg/data
  XDG_STATE_HOME=$R/xdg/state XDG_CACHE_HOME=$R/xdg/cache ZELLIJ_SOCKET_DIR=$R/sock PATH=$ISO_PATH
  USER=$USER_NAME LOGNAME=$USER_NAME LANG=en_US.UTF-8 TERM=xterm-256color SHELL=/bin/sh"

z_env() {
  # shellcheck disable=SC2086
  env $Z_ENV "$@"
}

Z() {
  say zellij "$@"
  z_env "$ZBIN" --config-dir "$R/config" --data-dir "$R/data" "$@"
}

ZA() {
  Z --session "$S" action "$@"
}

# shellcheck disable=SC2329
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ "$CREATED" = 1 ]; then
    Z kill-session "$S" >/dev/null 2>&1 || true
    sleep 1
    say rm -rf /tmp/sku-live-zellij
    rm -rf /tmp/sku-live-zellij
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# --- root, stubs, helpers -------------------------------------------------------------------------------------
say mkdir "$R"
mkdir "$R"
CREATED=1
mkdir "$R/bin" "$R/home" "$R/tmp" "$R/work" "$R/out" "$R/sock" "$R/config" "$R/data" \
  "$R/xdg" "$R/xdg/config" "$R/xdg/data" "$R/xdg/state" "$R/xdg/cache"
# nvim's driver and the plugin call `zellij` by name; the isolated PATH finds this link. The script runs $ZBIN.
ln -s "$ZBIN" "$R/bin/zellij"
printf 'show_startup_tips false\nshow_release_notes false\n' >"$R/config/config.kdl"

# Stub agent CLIs. The backend identifies a tool from the first word of the pane's command line, so each stub re-execs
# bash under its own name with `exec -a`. The stub puts its tty in raw mode and appends every byte it receives to
# $R/out/<name>-<pane number>.bytes, so a spec can tell text from Enter (CR). `Q` makes it exit. SKU_LIVE_ENV is written
# to <name>-<pane number>.env, to show that a tool env reaches the process.
make_stub() { # <name>
  cat >"$R/bin/$1" <<EOF
#!/bin/bash
if [ "\${SKU_STUB:-}" != "$1" ]; then
  SKU_STUB=$1 exec -a $1 /bin/bash "\$0" "\$@"
fi
base="$R/out/$1-\${ZELLIJ_PANE_ID:-x}"
printf '%s' "\${SKU_LIVE_ENV:-unset}" >"\$base.env"
: >"\$base.bytes"
stty raw -echo 2>/dev/null
echo "SKU-STUB $1 ready"
while IFS= read -r -n1 c; do
  printf '%s' "\$c" >>"\$base.bytes"
  [ "\$c" = Q ] && exit 0
done
EOF
  chmod +x "$R/bin/$1"
}
make_stub claude
make_stub codex

# Stub preflight: under the exact isolated PATH, claude and codex must resolve to the files written above. Nothing is
# executed. `registry.start` runs the bare name `claude`, so a missing stub would run a real CLI.
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

# Prints the id of the first terminal pane, or the basename of the first word of a pane's command line, from the JSON of
# `list-panes` on stdin. Only argv0 is ever printed, never the rest of a command line.
cat >"$R/zjson.lua" <<'EOF'
local panes = vim.json.decode(io.read("*a"))
local mode, want = arg[1], tonumber(arg[2])
for _, pane in ipairs(panes) do
  if not pane.is_plugin then
    if mode == "first" then
      io.write(tostring(pane.id))
      return
    elseif mode == "argv0" and pane.id == want then
      local word = (pane.pane_command or ""):match("^%s*(%S+)")
      io.write(word and vim.fs.basename(word) or "")
      return
    end
  end
end
EOF

cat >"$R/drive.lua" <<'EOF'
-- Driver run by headless nvim. Environment: SKU_REPO, SKU_OUT, SKU_PHASE, SKU_CWD, SKU_OUTDIR, SKU_SESSION (outside
-- phase), SKU_CLAUDE_PANE, SKU_CODEX_PANE, SKU_GONE_PANE (pane numbers).
local repo, out, phase = os.getenv("SKU_REPO"), os.getenv("SKU_OUT"), os.getenv("SKU_PHASE")
local outdir = os.getenv("SKU_OUTDIR")
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
local function zellij(session, ...)
  local res = vim.system({ "zellij", "--session", session, "action", ... }, { text = true }):wait()
  return res.stdout or "", res.code
end
---@return table[] the terminal panes of the session
local function terminals(session)
  local json = vim.json.decode((zellij(session, "list-panes", "--all", "--json", "--state")))
  return vim.tbl_filter(function(pane)
    return not pane.is_plugin
  end, json)
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
---Bytes the stub of `tool` in pane number `n` has received, or nil before it started.
local function received(tool, n)
  local file = io.open(("%s/%s-%s.bytes"):format(outdir, tool, n), "rb")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  return data
end
local function content(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  return data
end

local function run()
  require("sidekick-ultra").setup({
    herdr = { enabled = false },
    rex = { enabled = false },
    tmux = { enabled = false },
    tools = { claude = { env = { SKU_LIVE_ENV = "1" } } },
  })
  local registry = require("sidekick-ultra.registry")
  local tools = require("sidekick-ultra.tools")
  local backend = registry.backend("zellij")
  check("zellij backend registered", backend ~= nil)
  if not backend then
    return
  end

  if phase == "basic" then
    local session_name = os.getenv("SKU_SESSION")
    local a, b, g = os.getenv("SKU_CLAUDE_PANE"), os.getenv("SKU_CODEX_PANE"), os.getenv("SKU_GONE_PANE")
    local claude_id = ("zellij:%s:terminal_%s"):format(session_name, a)
    local codex_id = ("zellij:%s:terminal_%s"):format(session_name, b)
    check("inside() is false outside the mux", backend.inside() == false)
    local sessions = registry.discover()
    local claude, codex = find(sessions, claude_id), find(sessions, codex_id)
    check("discover finds the claude pane", claude ~= nil and claude.tool == "claude", sessions)
    check("discover finds the codex pane", codex ~= nil and codex.tool == "codex", sessions)
    if not (claude and codex) then
      return
    end
    check("cwd matches the pane cwd", real(claude.cwd) == real(os.getenv("SKU_CWD")), claude.cwd)
    check("no pid is recorded", claude.pid == nil, claude)
    check("session is running", registry.is_running(claude), claude)
    observe("claude session", claude)
    observe("codex session", codex)

    check("attach", registry.attach(claude) == true)
    check("attached() keeps it", #registry.attached() == 1)

    local ok, err = backend.send(claude, "hello-live")
    check("send succeeds", ok == true, err)
    vim.wait(800)
    local bytes = received("claude", a)
    check("sent text reaches the pane", bytes ~= nil and bytes:find("hello-live", 1, true) ~= nil, bytes)
    check("send did not press Enter", bytes ~= nil and bytes:find("\r", 1, true) == nil, bytes)
    ok, err = backend.submit(claude)
    check("submit succeeds", ok == true, err)
    vim.wait(800)
    bytes = received("claude", a)
    check("submit presses Enter", bytes ~= nil and bytes:find("\r", 1, true) ~= nil, bytes)

    ok, err = backend.focus(codex)
    check("focus succeeds", ok == true, err)
    local focused = {}
    for _, pane in ipairs(terminals(session_name)) do
      focused[tostring(pane.id)] = pane.is_focused
    end
    check("focus moved to the codex pane", focused[b] == true and focused[a] == false, focused)

    -- The pane in SKU_GONE_PANE ran a stub that exited on `Q`: it is exited or closed, and the guard must refuse.
    local gone = vim.tbl_extend("force", claude, {
      id = ("zellij:%s:terminal_%s"):format(session_name, g),
      pane = "terminal_" .. g,
    })
    check("a gone pane is not running", registry.is_running(gone) == false, gone)
    ok, err = backend.send(gone, "nope-live")
    check("send to a gone pane is refused", ok == nil and err and err.id == "backend_error", err)
    vim.wait(500)
    local missing = vim.tbl_extend("force", claude, { id = "zellij:" .. session_name .. ":terminal_9999", pane = "terminal_9999" })
    ok, err = backend.send(missing, "nope-live")
    check("send to a missing pane is refused", ok == nil and err and err.id == "backend_error", err)
    -- Probe P-Z7: without the guard zellij would exit 0 and drop the text. Recorded, not asserted.
    local _, code = zellij(session_name, "write-chars", "--pane-id", "terminal_9999", "--", "x")
    observe("bare write-chars to a missing pane exit code", code)

    local before = #terminals(session_name)
    local started, start_err = registry.start(tools.get("claude"))
    check("start outside the mux is refused", started == nil and start_err and start_err.id == "not_in_mux", start_err)
    check("refused start created no pane", #terminals(session_name) == before)
  elseif phase == "start" then
    local session_name = assert(os.getenv("ZELLIJ_SESSION_NAME"))
    local nvim_pane = assert(os.getenv("ZELLIJ_PANE_ID"))
    local a = os.getenv("SKU_CLAUDE_PANE")
    check("inside() is true in the pane", backend.inside() == true)
    local listed = registry.discover()
    check("discover lists the stub panes of nvim's own session", find(listed, ("zellij:%s:terminal_%s"):format(session_name, a)) ~= nil, listed)
    local before = #terminals(session_name)
    local session, err = registry.start(tools.get("claude"))
    check("start returns a session", session ~= nil, err)
    if not session then
      return
    end
    observe("started session", session)
    check("started session is running at once", registry.is_running(session), session)
    check("start created exactly one pane", #terminals(session_name) == before + 1)
    local focused = {}
    for _, pane in ipairs(terminals(session_name)) do
      focused["terminal_" .. pane.id] = pane.is_focused
    end
    check("start focused the new pane, not nvim's", focused[session.pane] == true and focused["terminal_" .. nvim_pane] == false, focused)
    local n = session.pane:match("^terminal_(%d+)$")
    vim.wait(1500)
    check("the tool env reached the process", content(("%s/claude-%s.env"):format(outdir, n)) == "1", content(("%s/claude-%s.env"):format(outdir, n)))
    check("attach started session", registry.attach(session) == true)
    local fresh = find(registry.discover(), session.id)
    check("rediscovery lists the started pane", fresh ~= nil and fresh.tool == "claude", fresh)
    if fresh then
      observe("rediscovered session", fresh)
      check("rediscovered session is running", registry.is_running(fresh), fresh)
      check("attached entry survived rediscovery", #registry.attached() == 1)
      local ok, send_err = backend.send(fresh, "start-live")
      check("send to the started pane", ok == true, send_err)
      vim.wait(800)
      local bytes = received("claude", n)
      check("started pane received the text", bytes ~= nil and bytes:find("start-live", 1, true) ~= nil, bytes)
      check("send did not press Enter", bytes ~= nil and bytes:find("\r", 1, true) == nil, bytes)
      ok, send_err = backend.submit(fresh)
      check("submit to the started pane", ok == true, send_err)
      vim.wait(800)
      bytes = received("claude", n)
      check("started pane received Enter", bytes ~= nil and bytes:find("\r", 1, true) ~= nil, bytes)
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

# --- session --------------------------------------------------------------------------------------------------
# Observation before any session exists in the private socket dir: the backend treats a non-zero exit with empty stdout
# and "No active zellij sessions" on stderr as an empty list. This records what zellij really does.
set +e
z_env "$ZBIN" --config-dir "$R/config" --data-dir "$R/data" list-sessions -n -s >"$R/out/nosession.stdout" 2>"$R/out/nosession.stderr"
rc=$?
set -e
{
  echo "exit: $rc"
  echo "stdout: $(cat "$R/out/nosession.stdout")"
  echo "stderr: $(cat "$R/out/nosession.stderr")"
} >"$R/out/nosession.txt"

Z attach --create-background "$S"
sleep 2

# Socket preflight: the session's socket must be under the root, or nothing below may run.
find "$R/sock" -name "$S" 2>/dev/null | grep -q . || {
  echo "refusing: no socket for $S under $R/sock" >&2
  find "$R/sock" >&2 || true
  exit 2
}
case "$(Z list-sessions -n -s)" in
  "$S") ;;
  *) die "the private socket dir does not list exactly the session $S" ;;
esac

# --- panes: A = stub claude, B = stub codex, G = stub claude that will exit, C = the first pane, a shell for nvim ---
jfirst() { "$NVIM" -u NONE -i NONE --headless -l "$R/zjson.lua" "$@"; }

pane_number() { # <new-pane output>
  case "$1" in
    terminal_[0-9]*) echo "${1#terminal_}" ;;
    *) die "new-pane printed no terminal id: $1" ;;
  esac
}

PANE_C=$(ZA list-panes --all --json --state | jfirst first)
case "$PANE_C" in "" | *[!0-9]*) die "could not read the first pane id" ;; esac
PANE_A=$(pane_number "$(ZA new-pane --direction right --no-focus --cwd "$R/work" --name sku-claude -- "$R/bin/claude")")
PANE_B=$(pane_number "$(ZA new-pane --direction right --no-focus --cwd "$R/work" --name sku-codex -- "$R/bin/codex")")
PANE_G=$(pane_number "$(ZA new-pane --direction right --no-focus --cwd "$R/work" --name sku-gone -- "$R/bin/claude")")
echo "panes: shell=$PANE_C claude=$PANE_A codex=$PANE_B gone=$PANE_G"

n=0
until [ -f "$R/out/claude-$PANE_A.bytes" ] && [ -f "$R/out/codex-$PANE_B.bytes" ] && [ -f "$R/out/claude-$PANE_G.bytes" ]; do
  n=$((n + 1))
  [ "$n" -le 40 ] || die "the stub panes did not start; their pane list is in $R/out"
  sleep 0.5
done

# The one open question of the argv0 mapping: what a stub's pane_command starts with. Only argv0 is printed.
ARGV0_A=$(ZA list-panes --all --json --command --state | jfirst argv0 "$PANE_A")
ARGV0_B=$(ZA list-panes --all --json --command --state | jfirst argv0 "$PANE_B")
echo "observed argv0: claude pane=[$ARGV0_A] codex pane=[$ARGV0_B]"
if [ "$ARGV0_A" != claude ] || [ "$ARGV0_B" != codex ]; then
  echo "UNVERIFIABLE: a stub's pane_command does not start with its name; discovery cannot be tested with this stub" >&2
  exit 3
fi

# Make the gone pane exit, and let zellij settle.
ZA write-chars --pane-id "terminal_$PANE_G" -- Q
sleep 1

# --- drive nvim outside the mux ---------------------------------------------------------------------------------
nv() {
  phase=$1
  say nvim "(headless, phase $phase, output $R/out/$phase.txt)"
  z_env \
    SKU_REPO="$REPO" SKU_OUT="$R/out/$phase.txt" SKU_PHASE="$phase" SKU_CWD="$R/work" SKU_OUTDIR="$R/out" \
    SKU_SESSION="$S" SKU_CLAUDE_PANE="$PANE_A" SKU_CODEX_PANE="$PANE_B" SKU_GONE_PANE="$PANE_G" \
    /usr/bin/perl -e 'alarm 90; exec @ARGV' -- "$NVIM" --headless -u NONE -i NONE -l "$R/drive.lua" || true
}

nv basic

# --- drive nvim inside the mux: typed into the first pane, which gives it ZELLIJ and ZELLIJ_PANE_ID --------------------
# The command is typed into the pane's own shell, which expands the ZELLIJ variables there. Everything else is passed
# through `env -i`, so nvim gets the same allowlist as the outside phase.
# The unquoted echo folds the newline of Z_ENV into a space; the typed command must be one line.
# shellcheck disable=SC2086,SC2116
Z_WORDS=$(echo $Z_ENV)
# shellcheck disable=SC2016
CMD="env $Z_WORDS"' ZELLIJ="$ZELLIJ" ZELLIJ_SESSION_NAME="$ZELLIJ_SESSION_NAME" ZELLIJ_PANE_ID="$ZELLIJ_PANE_ID"'
CMD="$CMD SKU_REPO=$REPO SKU_OUT=$R/out/start.txt SKU_PHASE=start SKU_CWD=$R/work SKU_OUTDIR=$R/out SKU_CLAUDE_PANE=$PANE_A"
CMD="$CMD $NVIM --headless -u NONE -i NONE -l $R/drive.lua"
ZA write-chars --pane-id "terminal_$PANE_C" -- "$CMD"
ZA send-keys --pane-id "terminal_$PANE_C" Enter
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
echo "== list-sessions with no session (observed before the session was created)"
cat "$R/out/nosession.txt"
for phase in basic start; do
  echo "== $phase"
  cat "$R/out/$phase.txt" 2>/dev/null || {
    echo "FAIL no output for phase $phase"
    fail=1
  }
  if grep -q '^FAIL' "$R/out/$phase.txt" 2>/dev/null; then fail=1; fi
  grep -q '^DONE' "$R/out/$phase.txt" 2>/dev/null || fail=1
done
if [ "$fail" = 0 ]; then
  echo "LIVE zellij: all checks passed"
else
  echo "LIVE zellij: FAILED"
fi
exit "$fail"
