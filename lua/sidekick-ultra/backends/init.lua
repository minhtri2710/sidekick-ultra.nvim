---The backend table: the one place that knows which backends exist, what options each takes and what `:checkhealth`
---reports about each. It is plain data with no `require`, so `config`, `health` and `:SidekickUltra` can read it without
---loading a backend module (a disabled backend is never loaded). The behavior lives in `backends/<name>.lua`; the
---contract is in `sidekick-ultra.backend`.
local M = {}

---@class sidekick_ultra.BackendOption
---@field type "string"|"boolean" a string option is never empty
---@field binary? boolean the option names the backend's binary: when that binary is unusable there is no fallback
---@field report? { set: string, unset: string } the `:checkhealth` row, after `<backend>: `, for set and unset

---@class sidekick_ultra.BackendInfo
---@field name string
---@field options table<string, sidekick_ultra.BackendOption> besides the common ones
---@field version? { flag: string, min?: integer[] } the flag that prints the version, and the oldest `{major, minor}`
---   that works: health warns below it
---@field server_vars? string[] variables with which the backend's program finds its server; health reports only
---   whether they are set

---The options every backend takes.
---@type table<string, sidekick_ultra.BackendOption>
M.common = { enabled = { type = "boolean" } }

---In the order health reports them.
---@type sidekick_ultra.BackendInfo[]
M.all = {
  {
    name = "herdr",
    options = {},
    server_vars = { "HERDR_SOCKET_PATH", "HERDR_SESSION" },
  },
  {
    name = "rex",
    options = {
      bin = { type = "string", binary = true },
      server = {
        type = "string",
        report = { set = "server is configured (rex.server)", unset = "rex.server is not configured" },
      },
    },
  },
  {
    name = "tmux",
    options = {
      socket = {
        type = "string",
        report = {
          set = "socket is configured (tmux.socket); every call uses -S",
          unset = "tmux.socket is not configured; calls go to the server of $TMUX, else the default server",
        },
      },
    },
    -- `paste-buffer -S`, which `send` needs, was added in 3.7 (CHANGES FROM 3.6b TO 3.7).
    version = { flag = "-V", min = { 3, 7 } },
  },
  {
    name = "zellij",
    options = {},
    version = { flag = "--version" },
  },
}

---@return string[]
function M.names()
  return vim.tbl_map(function(backend)
    return backend.name
  end, M.all)
end

return M
