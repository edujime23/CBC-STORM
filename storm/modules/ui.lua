-- /storm/modules/ui.lua
-- Controller UI: pairing + approvals screen.

local C = require("/storm/lib/config_loader")
local L = require("/storm/lib/logger")
local Join = require("/storm/core/join_service")
local U = require("/storm/lib/utils")

local M = {}

local function header()
  term.setCursorPos(1, 1)
  term.clearLine()
  term.write(("SKYNET ETERNAL v4.0 | Cluster: %s | Dim: %s"):format(C.system.cluster_id or "?", C.system.dimension or "?"))
end

local function footer()
  local _, h = term.getSize()
  term.setCursorPos(1, h)
  term.clearLine()
  term.write("[P] Pair  [A] Approvals  [Q] Quit")
end

local function pairing_info()
  local code = Join.get_active_code()
  local _, h = term.getSize()
  term.setCursorPos(1, h - 1)
  term.clearLine()
  if code then
    term.write("Pairing active. Join code (UI-only): " .. code)
  else
    term.write("Pairing idle.")
  end
end

local function approvals_screen()
  term.clear()
  header()
  local _, h = term.getSize()
  while true do
    term.setCursorPos(1, 3)
    term.clearLine()
    term.write("Pending join requests:")
    local list = Join.get_pending()
    for i = 1, 10 do
      term.setCursorPos(1, 3 + i)
      term.clearLine()
      local rec = list[i]
      if rec then
        term.write(("[%d] id=%s  kind=%s  dev=%s  age=%ds"):format(
          i, rec.id, tostring(rec.hello.node_kind), tostring(rec.hello.device_id), math.floor((U.now_ms() - rec.ts)/1000)
        ))
      end
    end

    term.setCursorPos(1, h - 2)
    term.clearLine()
    term.write("Enter number to approve, 'dN' to deny (e.g., d1), ENTER to refresh, ESC to exit.")
    term.setCursorPos(1, h - 1)
    term.clearLine()
    term.write("> ")
    local inp = read()
    if inp == "" then
      term.setCursorPos(1, 2); term.clearLine()
    elseif inp == "\27" then
      break
    elseif inp:match("^%d+$") then
      local idx = tonumber(inp)
      if not Join.approve_index(idx) then
        L.warn("system", "Approve failed: invalid index")
      end
    elseif inp:match("^d%d+$") then
      local idx = tonumber(inp:sub(2))
      if not Join.deny_index(idx) then
        L.warn("system", "Deny failed: invalid index")
      end
    end

    term.setCursorPos(1, 2)
    term.clearLine()
    term.write(("Pending: %d"):format(#Join.get_pending()))
  end
end

function M.run()
  term.clear()
  header()
  footer()
  pairing_info()

  while true do
    local ev, k = os.pullEvent()
    if ev == "key" then
      if k == keys.p then
        Join.start_pairing(300)
        L.info("system", "Pairing started from UI")
      elseif k == keys.a then
        approvals_screen()
        term.clear()
        header()
        footer()
        pairing_info()
      elseif k == keys.q then
        return
      end
    end

    pairing_info()
    U.sleep_ms(100)
  end
end

return M