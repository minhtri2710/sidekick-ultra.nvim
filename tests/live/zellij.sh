#!/bin/sh
# DRAFT for D8. Live run of the zellij backend against a private zellij session and stub agent CLIs.
# Written, not run, by the D8 Engineer. The Lead sends this recipe to the Supervisor before the first run.
#
# What it does: creates a background zellij session under the literal root /tmp/sku-live-zellij (own HOME, XDG dirs,
# config dir, data dir and ZELLIJ_SOCKET_DIR) FROM A LAYOUT FILE and drives headless nvim with the plugin.
# Why a layout at creation: zellij 0.45.1 sizes a tab from an attached client. A tab made later by `new-tab` in a session
# with no client is 0x0 ("Not enough room for panes"); its panes never show in list-panes and the tab is dropped when a
# client attaches (zellij issues 5594 and 5664, 0.45.1). Tabs of the creation layout are the way around it. The layout:
#   tab "nvim":  pane sku-nvim (the default shell, where nvim is typed; nothing else, so the inside start has room)
#   tab "stubs": panes sku-claude and sku-codex side by side (stub agents)
#   tab "gone":  pane sku-gone (a stub that ends on its first byte)
#   tab "shell": pane sku-shell (/bin/sh, with the claude stub typed into it)
# No tab-bar or status-bar plugin panes. The panes are found by their layout name (list-panes `title`), never by command.
# Floating panes are not used: with one visible, zellij silently creates no tiled pane at all.
#   outside the mux: discover, attach, send (no Enter), submit, cross-tab focus, the gone-pane guard, the not_in_mux
#                    refusal;
#   inside the mux (nvim typed into the sku-nvim pane): inside(), discover, start through registry.start (focused per D7,
#                    in nvim's tab and right of nvim's pane, with a tool env), the attach and status-refresh path (N2),
#                    running at once (start waits up to 2 s for the pane's argv0 to be the tool, past the env
#                    wrapper) and within 3 s, rediscovery, send, submit. The `new-pane` call is observed: exit code, stdout,
#                    stderr first line, time and pane counts before and after (never a command line).
# After the phases, one split-right in the "gone" tab is repeated (at most 6 times) until a split prints no id, to record
# what a no-room `new-pane` does. It is an observation, never a gate.
#
# The layout reaches the session by one of three forms; no probe ran any of them, so each is checked right after use
# against list-panes (names, tabs, sizes) and the next one is tried when the check fails:
#   layout-flag     zellij --layout F attach --create-background S
#   options-flag    zellij attach --create-background S options --default-layout F
#   config-default  default_layout "F" in the config file, then zellij attach --create-background S
# The form that held is printed. If none holds, the run stops with a FATAL that lists all three.
#
# A list-panes answer can be empty (exit 0, nothing printed; the server gives up after 1 s). Every empty answer prints a
# line with the call, its exit code and its first stderr line, and is retried within a bound; nothing is silent. Every
# setup step that fails stops the run with a FATAL naming the step.
#
# It never lists or touches another session: every zellij call runs under `env -i` with ZELLIJ_SOCKET_DIR under the
# root, so the Human's sessions are not even visible. It never runs kill-all-sessions or delete-all-sessions.
set -eu

[ "${SKU_LIVE:-}" = 1 ] || {
  echo "refusing: set SKU_LIVE=1 to run the live zellij test" >&2
  exit 2
}

R=/tmp/sku-live-zellij
SESSIONS="skulive skulive-b skulive-c"
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
ZBIN=$(command -v zellij) || die "preflight: zellij is not on PATH"
NVIM=$(command -v nvim) || die "preflight: nvim is not on PATH"
case "$ZBIN" in */tests/bin/*) die "preflight: zellij resolves to a test stub: $ZBIN" ;; esac

[ -e "$R" ] && die "preflight: $R already exists; remove it yourself after looking at it"

CREATED=0

# The one PATH every pane, client and the server get: the stubs and zellij's symlink, then the system dirs. No host
# bin directory, so the real claude and codex CLIs are not reachable even if a stub goes missing.
ISO_PATH="$R/bin:/usr/bin:/bin"

# The one environment every zellij client, the server and the nvim driver run in, as `env` words: an allowlist, `env -i`
# plus explicit assignments. A `-u` blocklist can never be complete (ENV, BASH_ENV, PROMPT_COMMAND, exported bash
# functions and names we do not know would get through). Every value is a plain word (the root is a literal path, the
# user name comes from `id -un`), so none has a space or a glob character and the unquoted expansions below split
# correctly. ZELLIJ_SOCKET_DIR is what keeps the Human's sessions out of reach.
USER_NAME=$(id -un) || die "preflight: id -un failed"
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

# Only kill-session, and only of the session names this script can have made. Never kill-all-sessions.
# shellcheck disable=SC2329
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ "$CREATED" = 1 ]; then
    for name in $SESSIONS; do
      Z kill-session "$name" >/dev/null 2>&1 || true
    done
    sleep 1
    say rm -rf /tmp/sku-live-zellij
    rm -rf /tmp/sku-live-zellij
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# --- root, stubs, helpers -------------------------------------------------------------------------------------
say mkdir "$R"
mkdir "$R" || die "setup: mkdir $R"
CREATED=1
mkdir "$R/bin" "$R/home" "$R/tmp" "$R/work" "$R/out" "$R/sock" "$R/config" "$R/data" \
  "$R/xdg" "$R/xdg/config" "$R/xdg/data" "$R/xdg/state" "$R/xdg/cache" || die "setup: mkdir of the root's directories"
# nvim's driver and the plugin call `zellij` by name; the isolated PATH finds this link. The script runs $ZBIN.
ln -s "$ZBIN" "$R/bin/zellij" || die "setup: link to zellij"


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

# The layout (KDL). Pane `name`s are what the script looks for; cwd is the work directory. `default_tab_template` with
# only `children` leaves out the tab-bar and status-bar plugin panes.
cat >"$R/layout.kdl" <<EOF
layout {
    default_tab_template {
        children
    }
    tab name="nvim" {
        pane name="sku-nvim" cwd="$R/work"
    }
    tab name="stubs" split_direction="vertical" {
        pane name="sku-claude" command="$R/bin/claude" cwd="$R/work"
        pane name="sku-codex" command="$R/bin/codex" cwd="$R/work"
    }
    tab name="gone" {
        pane name="sku-gone" command="$R/bin/gone" cwd="$R/work"
    }
    tab name="shell" {
        pane name="sku-shell" command="/bin/sh" cwd="$R/work"
    }
}
EOF

# Reads the JSON of `list-panes` on stdin and prints one answer by mode. Empty or invalid input stops with a message that
# names the calling step (SKU_STEP) and exit 3. It never prints a command line: argv0 is the basename of the first word
# of a pane_command, and a title is printed only when it is one of the layout's own names.
#   first        id of the first terminal pane          max          highest terminal pane id (or -1)
#   newer N      id of the first terminal pane above N  tabof N      tab_id of terminal pane N
#   argv0 N      argv0 of terminal pane N               count [T]    number of terminal panes (of tab T)
#   byname NAME  id of the terminal pane titled NAME    cols N       pane_columns of terminal pane N
#   titles       "id tab columns title" per terminal pane (a title not starting with sku- is shown as "(other)")
#   desc T       one line per terminal pane of tab T: id, floating, suppressed, stacked, exited
cat >"$R/zjson.lua" <<'EOF'
local step = os.getenv("SKU_STEP") or "?"
local function fail(reason)
  io.stderr:write(("FATAL zjson (step: %s): %s\n"):format(step, reason))
  os.exit(3)
end
local raw = io.read("*a")
if raw == nil or not raw:find("%S") then
  fail("empty input (zellij printed nothing)")
end
local ok, panes = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
if not ok or type(panes) ~= "table" then
  fail("input is not JSON")
end
local mode, want = arg[1], tonumber(arg[2])
local terminals = {}
for _, pane in ipairs(panes) do
  if type(pane) == "table" and not pane.is_plugin then
    table.insert(terminals, pane)
  end
end
local function find(id)
  for _, pane in ipairs(terminals) do
    if pane.id == id then
      return pane
    end
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
elseif mode == "tabof" or mode == "argv0" or mode == "cols" then
  local pane = find(want)
  if pane == nil then
    return
  end
  if mode == "tabof" then
    io.write(tostring(pane.tab_id))
  elseif mode == "cols" then
    io.write(tostring(pane.pane_columns))
  else
    local word = (pane.pane_command or ""):match("^%s*(%S+)")
    io.write(word and vim.fs.basename(word) or "")
  end
elseif mode == "byname" then
  for _, pane in ipairs(terminals) do
    if pane.title == arg[2] then
      io.write(tostring(pane.id))
      return
    end
  end
elseif mode == "titles" then
  for _, pane in ipairs(terminals) do
    local title = type(pane.title) == "string" and pane.title:sub(1, 4) == "sku-" and pane.title or "(other)"
    io.write(("%s %s %s %s\n"):format(pane.id, tostring(pane.tab_id), tostring(pane.pane_columns), title))
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
else
  fail("unknown mode " .. tostring(mode))
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
  -- An empty answer (exit 0, nothing printed) is logged with its exit code and retried; it is never read as "no panes".
  for try = 1, 10 do
    local stdout, code = zellij(session, "list-panes", "--all", "--json", "--state")
    if stdout:find("%S") then
      local ok, json = pcall(vim.json.decode, stdout)
      assert(ok and type(json) == "table", "driver terminals(): list-panes printed invalid JSON")
      return vim.tbl_filter(function(pane)
        return not pane.is_plugin
      end, json)
    end
    log(("EMPTY answer (driver terminals): list-panes exit=%s (try %d of 10)"):format(tostring(code), try))
    vim.wait(500)
  end
  error("driver terminals(): list-panes stayed empty after 10 tries")
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
    -- list-tabs --json has an `active` flag per tab (zellij docs, programmatic control). Observed, not gated.
    local tabs_out, tabs_code = zellij(session_name, "list-tabs", "--json")
    local active_tab
    if tabs_code == 0 then
      local okj, tabs = pcall(vim.json.decode, tabs_out)
      for _, tab in ipairs(okj and type(tabs) == "table" and tabs or {}) do
        if tab.active then
          active_tab = tab.tab_id
        end
      end
    end
    observe("active tab after the cross-tab focus (list-tabs exit, active tab_id)", { tabs_code, active_tab })
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
    local started_at = vim.uv.hrtime()
    local session, err = registry.start(tools.get("claude"))
    local start_ms = math.floor((vim.uv.hrtime() - started_at) / 1e6)
    exec.run = run
    check("start returns a session", session ~= nil, err)
    if not session then
      return
    end
    observe("started session", session)
    observe("registry.start duration ms (new-pane, the wait for the tool as argv0, focus)", start_ms)
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
        -- start returns only once the pane's argv0 matches the tool, so this holds at once.
    check("started session is running at once", registry.is_running(session) == true, session)
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

# --- listing helpers -------------------------------------------------------------------------------------------
# `snap_try <step> [extra list-panes flags]` stores the JSON of `list-panes --all --json --state` in $R/out/snap.json. An
# empty answer (exit 0 and nothing printed, a timeout in the server) prints a line with the call, its exit code and its
# first stderr line, then retries SNAP_TRIES times, 0.5 s apart. It returns 1 when the answer stays empty. `snap` stops the
# run instead, naming the step.
SNAP_TRIES=10
snap_try() {
  step=$1
  shift
  tries=0
  while :; do
    say zellij --session "$S" action list-panes --all --json --state "$@"
    set +e
    z_env "$ZBIN" --config-dir "$R/config" --data-dir "$R/data" --session "$S" action list-panes --all --json --state "$@" \
      >"$R/out/snap.json" 2>"$R/out/snap.err"
    rc=$?
    set -e
    if grep -q '[^[:space:]]' "$R/out/snap.json"; then
      return 0
    fi
    tries=$((tries + 1))
    echo "EMPTY answer ($step): list-panes --all --json --state $* exit=$rc stderr1=[$(head -n 1 "$R/out/snap.err")] (try $tries of $SNAP_TRIES)" >&2
    [ "$tries" -lt "$SNAP_TRIES" ] || return 1
    sleep 0.5
  done
}
snap() {
  snap_try "$@" || die "$1: list-panes stayed empty after $SNAP_TRIES tries"
}

# `jf <step> <mode> [argument]` runs zjson.lua on $R/out/snap.json under the isolated environment. Use it as
# `x=$(jf step mode arg) || die "step: ..."`; zjson.lua names the step on a bad input.
jf() {
  step=$1
  shift
  z_env SKU_STEP="$step" "$NVIM" -u NONE -i NONE --headless -l "$R/zjson.lua" "$@" <"$R/out/snap.json"
}

# --- session, from the layout ---------------------------------------------------------------------------------
write_config() { # <form>
  printf 'show_startup_tips false\nshow_release_notes false\nsession_serialization false\n' >"$R/config/config.kdl"
  if [ "$1" = config-default ]; then
    printf 'default_layout "%s"\n' "$R/layout.kdl" >>"$R/config/config.kdl"
  fi
}

# Observation before any session exists in the private socket dir: the backend treats a non-zero exit with empty stdout
# and "No active zellij sessions" on stderr as an empty list. This records what zellij really does.
write_config none
set +e
z_env "$ZBIN" --config-dir "$R/config" --data-dir "$R/data" list-sessions -n -s >"$R/out/nosession.stdout" 2>"$R/out/nosession.stderr"
rc=$?
set -e
{
  echo "exit: $rc"
  echo "stdout: $(cat "$R/out/nosession.stdout")"
  echo "stderr: $(cat "$R/out/nosession.stderr")"
} >"$R/out/nosession.txt"

# After a form was used: the five named panes exist, in the right tabs, with a real size.
layout_ok() { # <form>
  form_=$1
  snap_try "layout check ($form_)" || {
    echo "layout form $form_: list-panes stayed empty" >&2
    return 1
  }
  ids=""
  for name in sku-nvim sku-claude sku-codex sku-gone sku-shell; do
    id=$(jf "layout check ($form_)" byname "$name") || return 1
    if [ -z "$id" ]; then
      echo "layout form $form_: no pane titled $name; panes seen (id tab columns title):" >&2
      jf "layout check ($form_)" titles >&2 || true
      return 1
    fi
    cols=$(jf "layout check ($form_)" cols "$id") || return 1
    case "$cols" in "" | *[!0-9]*) cols=0 ;; esac
    if [ "$cols" -lt 10 ]; then
      echo "layout form $form_: pane $name is $cols columns wide (a tab without a real size?)" >&2
      return 1
    fi
    ids="$ids $id"
  done
  # shellcheck disable=SC2086
  set -- $ids
  t_nvim=$(jf "layout check ($form_)" tabof "$1") || return 1
  t_claude=$(jf "layout check ($form_)" tabof "$2") || return 1
  t_codex=$(jf "layout check ($form_)" tabof "$3") || return 1
  t_gone=$(jf "layout check ($form_)" tabof "$4") || return 1
  t_shell=$(jf "layout check ($form_)" tabof "$5") || return 1
  if [ "$t_claude" != "$t_codex" ] || [ "$t_nvim" = "$t_claude" ] || [ "$t_gone" = "$t_claude" ] || [ "$t_shell" = "$t_claude" ] || [ "$t_gone" = "$t_shell" ] || [ "$t_nvim" = "$t_gone" ] || [ "$t_nvim" = "$t_shell" ]; then
    echo "layout form $form_: the tabs are not as in the layout: nvim=$t_nvim claude=$t_claude codex=$t_codex gone=$t_gone shell=$t_shell" >&2
    return 1
  fi
  PANE_C=$1 PANE_A=$2 PANE_B=$3 PANE_G=$4 PANE_H=$5
  return 0
}

# Create the session with one form (bounded by a 20 s alarm in case a form waits for a terminal), then check it.
LAYOUT_FORM=
for attempt in "layout-flag skulive" "options-flag skulive-b" "config-default skulive-c"; do
  # shellcheck disable=SC2086
  set -- $attempt
  form=$1
  S=$2
  write_config "$form"
  set +e
  case "$form" in
    layout-flag)
      say zellij --layout "$R/layout.kdl" attach --create-background "$S"
      z_env /usr/bin/perl -e 'alarm 20; exec @ARGV' -- "$ZBIN" --config-dir "$R/config" --data-dir "$R/data" --layout "$R/layout.kdl" attach --create-background "$S"
      ;;
    options-flag)
      say zellij attach --create-background "$S" options --default-layout "$R/layout.kdl"
      z_env /usr/bin/perl -e 'alarm 20; exec @ARGV' -- "$ZBIN" --config-dir "$R/config" --data-dir "$R/data" attach --create-background "$S" options --default-layout "$R/layout.kdl"
      ;;
    config-default)
      say zellij attach --create-background "$S" "(default_layout in $R/config/config.kdl)"
      z_env /usr/bin/perl -e 'alarm 20; exec @ARGV' -- "$ZBIN" --config-dir "$R/config" --data-dir "$R/data" attach --create-background "$S"
      ;;
  esac
  create_rc=$?
  set -e
  echo "layout form $form: create exit=$create_rc"
  sleep 2
  # Socket preflight: the session's socket must be under the root, or nothing below may run.
  if ! find "$R/sock" -name "$S" 2>/dev/null | grep -q .; then
    echo "layout form $form: no socket for $S under $R/sock" >&2
    find "$R/sock" >&2 || true
  elif layout_ok "$form"; then
    LAYOUT_FORM=$form
    break
  fi
  # A form that did not hold: kill its session (this name only) before the next form is tried.
  Z kill-session "$S" >/dev/null 2>&1 || true
  sleep 1
done
[ -n "$LAYOUT_FORM" ] || die "setup: no way of giving zellij the layout held (tried layout-flag, options-flag, config-default; see the lines above)"
echo "layout form that held: $LAYOUT_FORM (session $S)"

# Session preflight: the private socket dir lists exactly this session.
set +e
Z list-sessions -n -s >"$R/out/sessions.txt" 2>"$R/out/sessions.err"
rc=$?
set -e
[ "$rc" = 0 ] || die "preflight: list-sessions exit=$rc: $(head -n 1 "$R/out/sessions.err")"
[ "$(cat "$R/out/sessions.txt")" = "$S" ] || die "preflight: the private socket dir does not list exactly the session $S"

echo "panes: nvim=$PANE_C claude=$PANE_A codex=$PANE_B gone=$PANE_G typed=$PANE_H"

n=0
until [ -f "$R/out/claude-$PANE_A.bytes" ] && [ -f "$R/out/codex-$PANE_B.bytes" ] && [ -f "$R/out/claude-$PANE_G.env" ]; do
  n=$((n + 1))
  [ "$n" -le 40 ] || die "setup: the stub panes did not start (no recorder file in $R/out)"
  sleep 0.5
done

# The one open question of the argv0 mapping: what a stub's pane_command starts with. Only argv0 is printed.
snap "argv0 preflight" --command
ARGV0_A=$(jf "argv0 preflight (claude)" argv0 "$PANE_A") || die "argv0 preflight: could not read the claude pane"
ARGV0_B=$(jf "argv0 preflight (codex)" argv0 "$PANE_B") || die "argv0 preflight: could not read the codex pane"
echo "observed argv0: claude pane=[$ARGV0_A] codex pane=[$ARGV0_B]"
if [ "$ARGV0_A" != claude ] || [ "$ARGV0_B" != codex ]; then
  echo "UNVERIFIABLE: a stub's pane_command does not start with its name; discovery cannot be tested with this stub" >&2
  exit 3
fi

# Type the stub into the shell pane and observe, as argv0 only, what its pane_command starts with. This is an
# observation, not a gate: the driver reports whether discovery found the pane.
ZA write-chars --pane-id "terminal_$PANE_H" -- claude || die "setup: typing the stub into the shell pane"
ZA send-keys --pane-id "terminal_$PANE_H" Enter || die "setup: pressing Enter in the shell pane"
n=0
until [ -f "$R/out/claude-$PANE_H.bytes" ]; do
  n=$((n + 1))
  [ "$n" -le 20 ] || break
  sleep 0.5
done
snap_try "argv0 of the typed pane" --command && echo "observed argv0: typed-into-shell pane=[$(jf "argv0 of the typed pane" argv0 "$PANE_H" || echo unreadable)]"

# Make the gone pane exit, and let zellij settle.
ZA write-chars --pane-id "terminal_$PANE_G" -- Q || die "setup: ending the gone pane"
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

# --- drive nvim inside the mux: typed into the sku-nvim pane, which gives it ZELLIJ and ZELLIJ_PANE_ID --------------------
# The command is typed into the pane's own shell, which expands the ZELLIJ variables there. Everything else is passed
# through `env -i`, so nvim gets the same allowlist as the outside phase.
# The unquoted echo folds the newline of Z_ENV into a space; the typed command must be one line.
# shellcheck disable=SC2086,SC2116
Z_WORDS=$(echo $Z_ENV)
# shellcheck disable=SC2016
CMD="env $Z_WORDS"' ZELLIJ="$ZELLIJ" ZELLIJ_SESSION_NAME="$ZELLIJ_SESSION_NAME" ZELLIJ_PANE_ID="$ZELLIJ_PANE_ID"'
CMD="$CMD SKU_REPO=$REPO SKU_OUT=$R/out/start.txt SKU_PHASE=start SKU_CWD=$R/work SKU_OUTDIR=$R/out SKU_CLAUDE_PANE=$PANE_A"
CMD="$CMD $NVIM --headless -u NONE -i NONE -l $R/drive.lua"
ZA write-chars --pane-id "terminal_$PANE_C" -- "$CMD" || die "inside phase: typing the nvim command into the sku-nvim pane"
ZA send-keys --pane-id "terminal_$PANE_C" Enter || die "inside phase: pressing Enter in the sku-nvim pane"
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
# In the "gone" tab (its only pane has ended, and the phases are over), split right until a split prints no id, at most 6
# times. Every call is recorded: exit code, stdout, stderr first line, the session's terminal-pane count before and after,
# and the panes of the tab (floating, suppressed, stacked, exited). It never fails the run, an empty list answer is
# printed and ends the loop, and no command line is read.
noroom() {
  set +e
  if ! snap_try "no-room: tab of the gone pane"; then
    echo "no-room: list-panes stayed empty; nothing recorded"
    return 0
  fi
  tab=$(jf "no-room: tab of the gone pane" tabof "$PANE_G")
  case "$tab" in "" | *[!0-9]*)
    echo "no-room: no tab for the gone pane ($tab); nothing recorded"
    return 0
    ;;
  esac
  i=1
  while [ "$i" -le 6 ]; do
    snap_try "no-room: count before" || {
      echo "no-room: count before is unavailable"
      return 0
    }
    before=$(jf "no-room: count before" count)
    out=$(ZA new-pane --tab-id "$tab" --direction right --no-focus --cwd "$R/work" --name sku-room -- /bin/sleep 120 2>"$R/out/noroom.err")
    rc=$?
    err1=$(grep -v '^+ ' "$R/out/noroom.err" | head -n 1)
    sleep 0.5
    after=unavailable
    if snap_try "no-room: count after"; then
      after=$(jf "no-room: count after" count)
    fi
    echo "split $i: exit=$rc stdout=[$out] stderr1=[$err1] terminal panes $before -> $after"
    case "$out" in
      terminal_[0-9]*) ;;
      *)
        echo "no id on split $i; panes of the tab:"
        if snap_try "no-room: panes of the tab"; then
          jf "no-room: panes of the tab" desc "$tab"
        fi
        break
        ;;
    esac
    i=$((i + 1))
  done
  return 0
}
noroom >"$R/out/noroom.txt" 2>&1 || true

# --- report ----------------------------------------------------------------------------------------------------
fail=0
echo "== layout form that held: $LAYOUT_FORM"
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
