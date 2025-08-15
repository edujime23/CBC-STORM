-- /storm/core/join_service.lua
-- Secure pairing (operator-chosen port, no discovery) + heavy debug + PAIR_READY ping.

local U  = require("/storm/lib/utils")
local C  = require("/storm/lib/config_loader")
local L  = require("/storm/lib/logger")
local HS = require("/storm/encryption/handshake") -- no crypto used; only code check

local DEBUG = true

local M = {
  pairing_active   = false,
  expires          = 0,
  code             = "",
  port             = nil,
  pending          = {},
  approved         = {},
  attempts         = {},
  quarantine       = {},
  _modem           = nil,
  _last_ready_ms   = 0
}

local function cfg_attempt_limit() return (C.security and C.security.pairing_attempt_limit) or 4 end
local function cfg_quarantine_ttl() return (C.security and C.security.quarantine_ttl_ms) or (15*60*1000) end
local function cfg_pairing_window() return (C.system and C.system.join_psk_window_s and C.system.join_psk_window_s*1000) or (5*60*1000) end
local function now() return U.now_ms() end

local function modem_or_error()
  if M._modem and peripheral.getName(M._modem) then return M._modem end
  local m = peripheral.find("modem")
  if not m then error("No modem found") end
  M._modem = m
  local name = peripheral.getName(m) or "modem"
  local wireless = (m.isWireless and m.isWireless()) and "true" or "false"
  if DEBUG then print(("[JoinService] Modem: %s | Wireless: %s"):format(name, wireless)) end
  return m
end

local function dbg_open_channels(tag, ch)
  local m = modem_or_error()
  if DEBUG then
    print(("[JoinService][%s] isOpen(%d)=%s"):format(tag, ch, tostring(m.isOpen and m.isOpen(ch) or false)))
  end
end

local function ensure_only_port_open(port)
  local m = modem_or_error()
  if m.closeAll then pcall(function() m.closeAll() end) end
  if not m.isOpen(port) then pcall(function() m.open(port) end) end
  dbg_open_channels("ensure_only_port_open", port)
end

local function close_port(port)
  local m = modem_or_error()
  if port and m.isOpen(port) then pcall(function() m.close(port) end) end
  dbg_open_channels("close_port", port)
end

local function send_on(tbl)
  local m = modem_or_error()
  if not M.port then return end
  if DEBUG then print(("[JoinService] TX on %d: %s"):format(M.port, type(tbl)=="table" and (tbl.type or "table") or tostring(tbl))) end
  m.transmit(M.port, M.port, tbl)
end

local function read_number(prompt, minv, maxv)
  while true do
    term.setCursorPos(1, 4); term.clearLine(); io.write(prompt)
    local s = read()
    local n = tonumber(s)
    if n and n >= minv and n <= maxv then return n end
    term.setCursorPos(1, 5); term.clearLine(); print(("Enter a number between %d and %d."):format(minv, maxv))
  end
end

local function generate_code4()
  return ("%04d"):format(math.random(0, 9999))
end

local function is_port_secure(port)
  local m = modem_or_error()
  if m.closeAll then pcall(function() m.closeAll() end) end
  if not m.isOpen(port) then pcall(function() m.open(port) end) end
  dbg_open_channels("sniff_start", port)

  print(("[JoinService] Testing port %d for noise (2s)..."):format(port))
  local t = os.startTimer(2.0)
  while true do
    local ev, side, channel, reply, msg, dist = os.pullEvent()
    if ev == "timer" and side == t then
      break
    elseif ev == "modem_message" then
      if channel == port then
        print(("[JoinService] Noise detected: ch=%d reply=%s type=%s dist=%s"):format(channel, tostring(reply), type(msg)=="table" and (msg.type or "table") or type(msg), tostring(dist)))
        return false
      elseif DEBUG then
        print(("[JoinService] Ignored traffic: ch=%d (not %d)"):format(channel, port))
      end
    end
  end
  print("[JoinService] Port appears quiet. Proceeding.")
  return true
end

function M.start_pairing_interactive()
  M.pairing_active = false
  M.port, M.code = nil, ""

  local pairing_port
  while true do
    pairing_port = read_number("Enter secure pairing port (0-65535): ", 0, 65535)
    if is_port_secure(pairing_port) then break end
    term.setCursorPos(1, 6); term.clearLine(); print("Please choose a different port.")
  end

  ensure_only_port_open(pairing_port)

  M.port    = pairing_port
  M.code    = generate_code4()
  M.expires = now() + cfg_pairing_window()
  M.pairing_active = true
  M.attempts, M.quarantine = {}, {}
  M._last_ready_ms = 0

  L.info("system", ("Pairing started on port %d with code %s"):format(M.port, M.code))
  print(("[JoinService] Pairing ARMED: port=%d code=%s"):format(M.port, M.code))
end

function M.stop_pairing()
  if DEBUG then print("[JoinService] stop_pairing()") end
  if M.port then close_port(M.port) end
  M.pairing_active = false
  M.expires = 0
  M.code = ""
  M.port = nil
  L.info("system", "Pairing window closed")
end

function M.get_active_code()  return M.pairing_active and M.code or nil end
function M.get_active_port()  return M.pairing_active and M.port or nil end
function M.get_pending()      return M.pending end

local function push_pending(hello)
  local id = ("%d-%06d"):format(hello.device_id or 0, math.random(100000, 999999))
  local rec = { id = id, hello = hello, ch = M.port, side = "modem", ts = now() }
  table.insert(M.pending, rec)
  L.info("system", ("Join request queued: %s (%s)"):format(id, tostring(hello.node_kind)))
end

function M.approve_index(i)
  local rec = M.pending[i]
  if not rec then return false, "no_pending" end
  local lease = HS.issue_lease(rec.hello, C.security.lease_ttl_ms, {
    caps = { can_fire = true, can_aim = true },
    min_cooldown_ms = (C.security and C.security.min_cooldown_ms) or 3000
  })
  send_on({
    type       = "JOIN_WELCOME",
    accepted   = true,
    cluster_id = C.system.cluster_id,
    lease      = lease,
    policy     = lease.policy
  })
  table.insert(M.approved, { id = rec.id, lease = lease, hello = rec.hello, ts = now() })
  table.remove(M.pending, i)
  L.info("system", ("Approved join: %s"):format(rec.id))
  return true
end

function M.deny_index(i, reason)
  local rec = M.pending[i]
  if not rec then return false, "no_pending" end
  send_on({ type = "JOIN_WELCOME", accepted = false, reason = reason or "denied" })
  table.remove(M.pending, i)
  L.info("system", ("Denied join: %s"):format(rec.id))
  return true
end

local function handle_join_hello(msg)
  if not M.pairing_active or not M.port then return end

  local dev_id = msg.device_id or -1
  if DEBUG then print(("[JoinService] JOIN_HELLO from dev=%s code=%s"):format(tostring(dev_id), tostring(msg.code))) end

  local q = M.quarantine[dev_id]
  if q and q > now() then
    send_on({ type = "JOIN_DENY", reason = "quarantine", until_ms = q })
    L.warn("system", ("Quarantined device %s attempted pairing"):format(tostring(dev_id)))
    return
  end

  local ok_code = (type(msg.code) == "string" or type(msg.code) == "number") and (tostring(msg.code) == M.code)
  if not ok_code then
    local attempts = (M.attempts[dev_id] or 0) + 1
    M.attempts[dev_id] = attempts
    local left = math.max(0, cfg_attempt_limit() - attempts)
    if attempts >= cfg_attempt_limit() then
      local until_ms = now() + cfg_quarantine_ttl()
      M.quarantine[dev_id] = until_ms
      send_on({ type = "JOIN_DENY", reason = "attempts_exceeded", until_ms = until_ms })
      L.warn("system", ("Device %s exceeded pairing attempts; quarantined"):format(tostring(dev_id)))
    else
      send_on({ type = "JOIN_DENY", reason = "bad_code", attempts_left = left })
      L.warn("system", ("Bad code from device %s; left=%d"):format(tostring(dev_id), left))
    end
    return
  end

  push_pending(msg)
  print(("[JoinService] JOIN_HELLO accepted from device %s"):format(tostring(msg.device_id)))
  send_on({ type = "JOIN_ACK", queued = true })
end

local function handle_modem_message(side, channel, replyChannel, msg, dist)
  if DEBUG then
    local ty = (type(msg)=="table" and msg.type) or type(msg)
    print(("[JoinService] RX side=%s ch=%s reply=%s dist=%s type=%s active=%s port=%s")
      :format(tostring(side), tostring(channel), tostring(replyChannel), tostring(dist), tostring(ty), tostring(M.pairing_active), tostring(M.port)))
  end
  if not M.pairing_active then return end
  if not M.port or channel ~= M.port then return end
  if type(msg) ~= "table" then return end
  if msg.type == "JOIN_HELLO" then
    handle_join_hello(msg)
  end
end

function M.run()
  modem_or_error()
  while true do
    local t = os.startTimer(0.25)
    while true do
      local ev, p1, p2, p3, p4, p5 = os.pullEvent()
      if ev == "timer" and p1 == t then break
      elseif ev == "modem_message" then handle_modem_message(p1, p2, p3, p4, p5) end
    end

    -- Send a small READY ping once per second on the chosen port (for connectivity debug only)
    if M.pairing_active and M.port and (now() - (M._last_ready_ms or 0) > 1000) then
      send_on({ type = "PAIR_READY", port = M.port })
      M._last_ready_ms = now()
    end

    if M.pairing_active and now() > (M.expires or 0) then
      L.info("system", "Pairing window expired")
      M.stop_pairing()
    end
  end
end

return M