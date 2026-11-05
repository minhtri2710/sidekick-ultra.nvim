#!/bin/sh
# DRAFT for D8. Live run of the zellij backend against a private zellij session and stub agent CLIs.
# Written, not run, by the D8 Engineer. The Lead sends this recipe to the Supervisor before the first run.
#
# What it does: creates a background zellij session under the literal root /tmp/sku-live-zellij (own HOME, XDG dirs,
# config dir, data dir and ZELLIJ_SOCKET_DIR), adds stub-agent panes (claude, codex, a claude that exits on its first
# byte, and a /bin/sh pane that has the claude stub typed into it), and drives headless nvim with the plugin.
# Layout: the session is a headless 50 columns wide, and `new-pane --direction right` creates nothing when the tab has
# no room (zellij closes the freshly spawned pane and prints no id). So nvim's tab (the first one) holds only nvim's
# pane, which keeps the room for the inside start. The stubs live in other tabs, one tab for claude and codex (two panes
# side by side), one for the pane that exits, one for the shell pane. Floating panes are not used: with a floating pane
# visible, zellij silently creates no tiled pane at all. After the phases, a scratch tab is split right until a split
# prints no id, to record what a no-room `new-pane` does (a bounded observation, never a gate).
#   outside the mux: discover, attach, send (no Enter), submit, focus, the gone-pane guard, the not_in_mux start refusal;
#   inside the mux (nvim typed into the session's first pane): inside(), discover, start through registry.start (the new
#                    pane is focused per D7, beside nvim's pane and in its tab, with a tool env), running within 3 s,
#                    rediscovery, send, submit. The call of `new-pane` is observed: exit code, stdout, stderr first line,
#                    time and pane counts before and after (never a command line).
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

# Stub agent CLIs. The backend identifies a tool from the first word of the pane's command line, so each stub ends in
# `exec -a <name> /bin/dd`: the process is dd, named <name>. dd is the byte recorder of the probe (raw tty, bs=1): it
# appends every byte it receives to $R/out/<name>-<pane number>.bytes exactly as the tty delivers it, so a check can tell
# text from Enter (CR). bash's own `read` is not used, because it puts the tty in a mode that turns CR into LF. SKU_LIVE_ENV
# is written to <name>-<pane number>.env first, to show that a tool env reaches the process. The `gone` stub is the same
# but dd stops after its first byte, which ends the pane (the shell sends `Q`).
make_stub() { # <file> <argv0> <dd arguments>
  cat >"$R/bin/$1" <<EOF
#!/bin/bash
base="$R/out/$2-\${ZELLIJ_PANE_ID:-x}"
printf '%s' "\${SKU_LIVE_ENV:-unset}" >"\$base.env"
stty raw -echo 2>/dev/null
echo "SKU-STUB $2 ready"
exec -a $2 /bin/dd bs=1 $3 2>/dev/null
EOF
  chmod +x "$R/bin/$1"
}
# shellcheck disable=SC2016
make_stub claude claude 'of="$base.bytes"'
# shellcheck disable=SC2016
make_stub codex codex 'of="$base.bytes"'
make_stub gone claude 'count=1 of=/dev/null'

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

# Reads the JSON of `list-panes` on stdin and prints one answer by mode. Never a command line: argv0 is the basename of
# the first word of a pane_command, and nothing else of it is printed.
#   first        id of the first terminal pane           max          highest terminal pane id (or -1)
#   newer N      id of the first terminal pane above N   tabof N     tab_id of terminal pane N
#   argv0 N      argv0 of terminal pane N                count [T]    number of terminal panes (of tab T)
#   desc T       one line per terminal pane of tab T: id, floating, suppressed, stacked, exited
cat >"$R/zjson.lua" <<'EOF'
local panes = vim.json.decode(io.read("*a"))
local mode, want = arg[1], tonumber(arg[2])
local terminals = {}
for _, pane in ipairs(panes) do
  if not pane.is_plugin then
    table.insert(terminals, pane)
  end
end
if mode == "first" then
  io.write(terminals[1] and tostring(terminals[1].id) or "")
elseif mode == "max" then
  local max = -1
  for _, pane in ipairs(terminals) do
    max = math.max(max, pane.id)
  end
  io.write(tostring(max))
elseif mode == "newer" then
  for _, pane in ipairs(terminals) do
    if pane.id > want then
      io.write(tostring(pane.id))
      return
    end
  end
elseif mode == "tabof" or mode == "argv0" then
  for _, pane in ipairs(terminals) do
    if pane.id == want then
      if mode == "tabof" then
        io.write(tostring(pane.tab_id))
      else
        local word = (pane.pane_command or ""):match("^%s*(%S+)")
        io.write(word and vim.fs.basename(word) or "")
      end
      return
    end
  end
elseif mode == "count" then
  local n = 0
  for _, pane in ipairs(terminals) do
    if want == nil or pane.tab_id == want then
      n = n + 1
    end
  end
  io.write(tostring(n))
elseif mode == "desc" then
  for _, pane in ipairs(terminals) do
    if pane.tab_id == want then
      io.write(("id=%s floating=%s suppressed=%s stacked=%s exited=%s\n"):format(pane.id, tostring(pane.is_floating), tostring(pane.is_suppressed), tostring(pane.is_stacked), tostring(pane.exited)))
    end
  end
end
EOF

cat >"$R/drive.lua" <<'EOF'
-- Driver run by headless nvim. Environment: SKU_REPO, SKU_OUT, SKU_PHASE, SKU_CWD, SKU_OUTDIR, SKU_SESSION (outside
-- phase), SKU_CLAUDE_PANE, SKU_CODEX_PANE, SKU_GONE_PANE, SKU_SHELL_PANE, SKU_NVIM_PANE (pane numbers).
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
    local typed = find(sessions, ("zellij:%s:terminal_%s"):format(session_name, os.getenv("SKU_SHELL_PANE")))
    observe("claude stub typed into a /bin/sh pane is discovered", typed ~= nil)

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

    -- Start from nvim's own pane, which is in another tab than the stubs, so the focus below crosses tabs.
    local c = os.getenv("SKU_NVIM_PANE")
    zellij(session_name, "focus-pane-id", "terminal_" .. c)
    ok, err = backend.focus(codex)
    check("focus succeeds", ok == true, err)
    local focused, tab_of = {}, {}
    for _, pane in ipairs(terminals(session_name)) do
      focused[tostring(pane.id)] = pane.is_focused
      tab_of[tostring(pane.id)] = pane.tab_id
    end
    check("focus moved to the codex pane, not the claude pane", focused[b] == true and focused[a] == false, focused)
    observe("focus crossed tabs (codex tab vs nvim's tab)", { tab_of[b], tab_of[c] })
    observe("nvim's pane still flagged focused after the cross-tab focus", focused[c])

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
    -- Observe the call of new-pane at the exec seam: the result only (its stdout is a pane id), never the command line.
    local exec = require("sidekick-ultra.exec")
    local run = exec.run
    exec.run = function(argv, opts)
      if not vim.tbl_contains(argv, "new-pane") then
        return run(argv, opts)
      end
      local count, t0 = #terminals(session_name), vim.uv.hrtime()
      local res, run_err = run(argv, opts)
      observe("new-pane call", {
        exit = res and res.code,
        stdout = res and res.stdout,
        stderr_first_line = res and vim.split(res.stderr, "\n", { plain = true })[1],
        run_error = run_err and run_err.msg,
        ms = math.floor((vim.uv.hrtime() - t0) / 1e6),
        panes_before = count,
        panes_after = #terminals(session_name),
      })
      return res, run_err
    end
    -- The product path is start, attach, the ATTACH event, status.refresh, is_running. Watch the events.
    local detached, attach_fired = {}, false
    vim.api.nvim_create_autocmd("User", {
      pattern = registry.DETACH,
      callback = function(ev)
        detached[ev.data.id] = true
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      pattern = registry.ATTACH,
      callback = function()
        attach_fired = true
      end,
    })
    local session, err = registry.start(tools.get("claude"))
    exec.run = run
    check("start returns a session", session ~= nil, err)
    if not session then
      return
    end
    observe("started session", session)
    -- At once, as the product does: attach, then let the event loop run the status refresh (its autocmd was
    -- registered before this one, so it has run when this one fires).
    check("attach started session", registry.attach(session) == true)
    vim.wait(3000, function()
      return attach_fired
    end, 20)
    check("the ATTACH event ran", attach_fired)
    observe("is_running right after the status refresh", registry.is_running(session))
    local still = false
    for _, attached in ipairs(registry.attached()) do
      still = still or attached.id == session.id
    end
    check("the started session is still attached after the status refresh", still and not detached[session.id], { still, detached })
    -- The pane may still show the env wrapper or the stub's bash for a moment (the tool env is set through env).
    observe("started session is running at once", registry.is_running(session))
    check("started session is running within 3 s", vim.wait(3000, function()
      return registry.is_running(session)
    end, 200), session)
    check("start created exactly one pane", #terminals(session_name) == before + 1)
    local focused, by_id = {}, {}
    for _, pane in ipairs(terminals(session_name)) do
      focused["terminal_" .. pane.id] = pane.is_focused
      by_id["terminal_" .. pane.id] = pane
    end
    check("start focused the new pane, not nvim's", focused[session.pane] == true and focused["terminal_" .. nvim_pane] == false, focused)
    local new_pane, own_pane = by_id[session.pane], by_id["terminal_" .. nvim_pane]
    check("the new pane is in nvim's tab", new_pane ~= nil and own_pane ~= nil and new_pane.tab_id == own_pane.tab_id, { new_pane and new_pane.tab_id, own_pane and own_pane.tab_id })
    check("the new pane is right of nvim's pane", new_pane ~= nil and own_pane ~= nil and new_pane.pane_x > own_pane.pane_x, { new_pane and new_pane.pane_x, own_pane and own_pane.pane_x })
    local n = session.pane:match("^terminal_(%d+)$")
    vim.wait(1500)
    check("the tool env reached the process", content(("%s/claude-%s.env"):format(outdir, n)) == "1", content(("%s/claude-%s.env"):format(outdir, n)))
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
jfirst() { z_env "$NVIM" -u NONE -i NONE --headless -l "$R/zjson.lua" "$@"; }

pane_number() { # <new-pane output>
  case "$1" in
    terminal_[0-9]*) echo "${1#terminal_}" ;;
    *) die "new-pane printed no terminal id: $1" ;;
  esac
}

PANE_C=$(ZA list-panes --all --json --state | jfirst first)
case "$PANE_C" in "" | *[!0-9]*) die "could not read the first pane id" ;; esac

# A new tab whose only terminal pane runs the given command; prints that pane's number. The new pane is found as the
# first terminal pane above the highest id before the call (ids are never reused), and the tab keeps all of its room.
new_tab_pane() { # <tab name> <command and arguments>
  name=$1
  shift
  above=$(ZA list-panes --all --json --state | jfirst max)
  ZA new-tab --name "$name" --cwd "$R/work" -- "$@" >/dev/null
  tries=0
  while :; do
    found=$(ZA list-panes --all --json --state | jfirst newer "$above")
    case "$found" in "" | *[!0-9]*) ;; *) break ;; esac
    tries=$((tries + 1))
    [ "$tries" -le 20 ] || die "new-tab $name created no terminal pane"
    sleep 0.3
  done
  echo "$found"
}

PANE_A=$(new_tab_pane sku-stubs "$R/bin/claude")
TAB_A=$(ZA list-panes --all --json --state | jfirst tabof "$PANE_A")
case "$TAB_A" in "" | *[!0-9]*) die "could not read the tab of pane $PANE_A" ;; esac
# Two panes side by side in the stub tab fit; the focus check below needs two panes in one tab.
PANE_B=$(pane_number "$(ZA new-pane --tab-id "$TAB_A" --direction right --no-focus --cwd "$R/work" --name sku-codex -- "$R/bin/codex")")
PANE_G=$(new_tab_pane sku-gone "$R/bin/gone")
# A /bin/sh pane with the claude stub typed into it: the common real case, a tool that is the shell's child.
PANE_H=$(new_tab_pane sku-shell /bin/sh)
echo "panes: nvim=$PANE_C claude=$PANE_A codex=$PANE_B gone=$PANE_G typed=$PANE_H (stub tab $TAB_A)"

n=0
until [ -f "$R/out/claude-$PANE_A.bytes" ] && [ -f "$R/out/codex-$PANE_B.bytes" ] && [ -f "$R/out/claude-$PANE_G.env" ]; do
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

# Type the stub into the shell pane and observe, as argv0 only, what its pane_command starts with. This is an
# observation, not a gate: the driver reports whether discovery found the pane.
ZA write-chars --pane-id "terminal_$PANE_H" -- claude
ZA send-keys --pane-id "terminal_$PANE_H" Enter
n=0
until [ -f "$R/out/claude-$PANE_H.bytes" ]; do
  n=$((n + 1))
  [ "$n" -le 20 ] || break
  sleep 0.5
done
echo "observed argv0: typed-into-shell pane=[$(ZA list-panes --all --json --command --state | jfirst argv0 "$PANE_H")]"

# Make the gone pane exit, and let zellij settle.
ZA write-chars --pane-id "terminal_$PANE_G" -- Q
sleep 1

# --- drive nvim outside the mux ---------------------------------------------------------------------------------
nv() {
  phase=$1
  say nvim "(headless, phase $phase, output $R/out/$phase.txt)"
  z_env \
    SKU_REPO="$REPO" SKU_OUT="$R/out/$phase.txt" SKU_PHASE="$phase" SKU_CWD="$R/work" SKU_OUTDIR="$R/out" \
    SKU_SESSION="$S" SKU_CLAUDE_PANE="$PANE_A" SKU_CODEX_PANE="$PANE_B" SKU_GONE_PANE="$PANE_G" SKU_SHELL_PANE="$PANE_H" SKU_NVIM_PANE="$PANE_C" \
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

# --- the no-room case, once, on purpose ---------------------------------------------------------------------------
# A scratch tab (the phases are over, nothing else lives there) is split right until a split prints no id, at most 6
# times. Every call is recorded: exit code, stdout, stderr first line, the session's terminal-pane count before and after,
# and the panes of the tab (floating, suppressed, stacked, exited). It never fails the run, and no command line is read.
noroom() {
  set +e
  ZA new-tab --name sku-scratch --cwd "$R/work" >/dev/null 2>&1
  sleep 0.5
  tab=$(ZA list-panes --all --json --state | jfirst tabof "$(ZA list-panes --all --json --state | jfirst max)")
  i=1
  while [ "$i" -le 6 ]; do
    before=$(ZA list-panes --all --json --state | jfirst count)
    out=$(ZA new-pane --tab-id "$tab" --direction right --no-focus --cwd "$R/work" --name sku-room -- /bin/sleep 120 2>"$R/out/noroom.err")
    rc=$?
    err1=$(grep -v '^+ ' "$R/out/noroom.err" | head -n 1)
    sleep 0.5
    after=$(ZA list-panes --all --json --state | jfirst count)
    echo "split $i: exit=$rc stdout=[$out] stderr1=[$err1] terminal panes $before -> $after"
    case "$out" in
      terminal_[0-9]*) ;;
      *)
        echo "no id on split $i; panes of the scratch tab:"
        ZA list-panes --all --json --state | jfirst desc "$tab"
        break
        ;;
    esac
    i=$((i + 1))
  done
  set -e
}
noroom >"$R/out/noroom.txt" 2>&1 || true

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
echo "== no-room new-pane (observation)"
cat "$R/out/noroom.txt"
if [ "$fail" = 0 ]; then
  echo "LIVE zellij: all checks passed"
else
  echo "LIVE zellij: FAILED"
fi
exit "$fail"
