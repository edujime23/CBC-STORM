-- /storm/core/join_service.lua
-- Secure pairing on operator-chosen port; logs to /storm/journal/pairing.log
local U   = require("/storm/lib/utils")
local Cfg = require("/storm/lib/config_loader")
local Log = require("/storm/lib/logger")
local HS  = require("/storm/encryption/handshake")
local Net = require("/storm/encryption/netsec")

local DEBUG = false  -- set true only for debugging

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
  _modem_name      = nil,
  _last_ready_ms   = 0,
  sessions         = {},   -- dev_id -> session
  registry         = {},   -- dev_id -> {dev_id, lease, modem, channel, last_rtt, last_ping_ts}
}

local function cfg_attempt_limit() return (Cfg.security and Cfg.security.pairing_attempt_limit) or 4 end
local function cfg_quarantine_ttl() return (Cfg.security and Cfg.security.quarantine_ttl_ms) or (15*60*1000) end
local function cfg_pairing_window() return (Cfg.system and Cfg.system.join_psk_window_s and Cfg.system.join_psk_window_s*1000) or (5*60*1000) end
local function now() return U.now_ms() end

-- Prefer wireless modem. If none, error (as requested).
local function pick_wireless_modem()
  local names = peripheral.getNames()
  local first_modem = nil
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      if m then
        local isW = (m.isWireless and m.isWireless()) and true or false
        if isW then
          M._modem = m
          M._modem_name = name
          if DEBUG then print(("[JoinService] Selected wireless modem: %s"):format(name)) end
          return m
        end
        if not first_modem then first_modem = { obj=m, name=name } end
      end
    end
  end
  if first_modem then
    error(("No wireless modem found. Found only wired modem '%s'. Attach a wireless/ender modem and retry."):format(first_modem.name))
  else
    error("No modem found. Attach a wireless modem.")
  end
end

local function modem_or_error()
  if M._modem and peripheral.getName(M._modem) then return M._modem end
  return pick_wireless_modem()
end

local function dbg_open_channels(tag, ch)
  if not DEBUG then return end
  local m = modem_or_error()
  print(("[JoinService][%s][%s] isOpen(%d)=%s"):format(tag, M._modem_name or "?", ch, tostring(m.isOpen and m.isOpen(ch) or false)))
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
  Log.info("pairing", ("TX on %s/%d: %s"):format(M._modem_name or "modem", M.port, type(tbl)=="table" and (tbl.type or "table") or type(tbl)))
  m.transmit(M.port, M.port, tbl)
end

-- 2s port sniff for noise
local function is_port_secure(port)
  local m = modem_or_error()
  if m.closeAll then pcall(function() m.closeAll() end) end
  if not m.isOpen(port) then pcall(function() m.open(port) end) end
  dbg_open_channels("sniff_start", port)

  print(("[JoinService] Testing port %d on %s for noise (2s)..."):format(port, M._modem_name or "?"))
  local t = os.startTimer(2.0)
  while true do
    local ev, side, channel, reply, msg, dist = os.pullEvent()
    if ev == "timer" and side == t then
      break
    elseif ev == "modem_message" and channel == port then
      print(("[JoinService] Noise detected: ch=%d type=%s"):format(channel, type(msg)=="table" and (msg.type or "table") or type(msg)))
      return false
    end
  end
  print("[JoinService] Port appears quiet. Proceeding.")
  return true
end

-- Start pairing on a given port (called by UI)
function M.start_pairing_on_port(port)
  modem_or_error()
  local isW = (M._modem.isWireless and M._modem.isWireless()) and true or false
  print(("[JoinService] Using modem '%s' (Wireless=%s)"):format(M._modem_name or "?", tostring(isW)))

  if not (type(port)=="number" and port>=0 and port<=65535) then
    return false, "invalid_port"
  end
  if not is_port_secure(port) then
    return false, "noisy_port"
  end

  ensure_only_port_open(port)

  M.port    = port
  M.code    = ("%04d"):format(math.random(0, 9999))
  M.expires = now() + cfg_pairing_window()
  M.pairing_active = true
  M.attempts, M.quarantine, M.sessions, M.pending, M.approved, M.registry = {}, {}, {}, {}, {}, {}
  M._last_ready_ms = 0

  Log.info("system", ("Pairing started on %s port %d with code %s"):format(M._modem_name or "modem", M.port, M.code))
  print(("[JoinService] Pairing ARMED: port=%d code=%s"):format(M.port, M.code))
  return true
end

function M.stop_pairing()
  if M.port then close_port(M.port) end
  M.pairing_active = false
  M.expires = 0
  M.code = ""
  M.port = nil
  Log.info("system", "Pairing window closed")
end

function M.get_active_code()  return M.pairing_active and M.code or nil end
function M.get_active_port()  return M.pairing_active and M.port or nil end
function M.get_pending()      return M.pending end

-- Expose workers (approved) for UI
function M.get_workers()
  local list = {}
  for dev, rec in pairs(M.registry) do
    list[#list+1] = {
      dev_id = dev,
      modem  = rec.modem,
      channel= rec.channel,
      last_rtt = rec.last_rtt,
      lease = rec.lease
    }
  end
  table.sort(list, function(a,b) return tostring(a.dev_id) < tostring(b.dev_id) end)
  return list
end

-- Ping a worker over encrypted session
function M.ping_worker(dev_id)
  local sess = M.sessions[dev_id]
  if not sess then return false, "no_session" end
  local frame = Net.wrap(sess, { type="PING", ts=now() }, { dev = dev_id })
  send_on(frame)
  -- remember when we pinged
  local r = M.registry[dev_id]
  if r then r.last_ping_ts = now() end
  return true
end

local function push_pending(hello)
  local id = ("%d-%06d"):format(hello.device_id or 0, math.random(100000, 999999))
  local rec = { id = id, hello = hello, ch = M.port, side = M._modem_name or "modem", ts = now() }
  table.insert(M.pending, rec)
  Log.info("system", ("Join request queued: %s (%s)"):format(id, tostring(hello.node_kind)))
end

-- FIX: Do not send policy twice (no repeated table refs)
function M.approve_index(i)
  local rec = M.pending[i]
  if not rec then return false, "no_pending" end
  local sess = M.sessions[rec.hello.device_id]
  if not sess then
    Log.warn("pairing", "No session for approved device; cannot send WELCOME")
    return false, "no_session"
  end
  local dev_id = rec.hello.device_id
  local lease = HS.issue_lease(rec.hello, Cfg.security.lease_ttl_ms, {
    caps = { can_fire = true, can_aim = true },
    min_cooldown_ms = (Cfg.security and Cfg.security.min_cooldown_ms) or 3000
  })
  local frame = Net.wrap(sess, {
    type       = "JOIN_WELCOME",
    accepted   = true,
    cluster_id = Cfg.system.cluster_id,
    lease      = lease
  }, { dev = dev_id })
  send_on(frame)

  -- Register worker in registry
  M.registry[dev_id] = {
    dev_id = dev_id,
    lease  = lease,
    modem  = M._modem_name or "modem",
    channel= M.port,
    last_rtt = nil,
    last_ping_ts = nil
  }

  table.insert(M.approved, { id = rec.id, lease = lease, hello = rec.hello, ts = now() })
  table.remove(M.pending, i)
  Log.info("system", ("Approved join: %s"):format(rec.id))
  return true
end

function M.deny_index(i, reason)
  local rec = M.pending[i]
  if not rec then return false, "no_pending" end
  local sess = M.sessions[rec.hello.device_id]
  if sess then
    local frame = Net.wrap(sess, { type="JOIN_WELCOME", accepted=false, reason=reason or "denied" }, { dev = rec.hello.device_id })
    send_on(frame)
  else
    send_on({ type = "JOIN_WELCOME", accepted = false, reason = reason or "denied" })
  end
  table.remove(M.pending, i)
  Log.info("system", ("Denied join: %s"):format(rec.id))
  return true
end

local function handle_join_hello(msg)
  if not M.pairing_active or not M.port then return end
  local dev_id = msg.device_id or -1

  local q = M.quarantine[dev_id]
  if q and q > now() then
    send_on({ type = "JOIN_DENY", reason = "quarantine", until_ms = q })
    Log.warn("system", ("Quarantined device %s attempted pairing"):format(tostring(dev_id)))
    return
  end

  local ok, err = HS.verify_join_hello(msg, M.code)
  if not ok then
    local attempts = (M.attempts[dev_id] or 0) + 1
    M.attempts[dev_id] = attempts
    local left = math.max(0, cfg_attempt_limit() - attempts)
    if attempts >= cfg_attempt_limit() then
      local until_ms = now() + cfg_quarantine_ttl()
      M.quarantine[dev_id] = until_ms
      send_on({ type = "JOIN_DENY", reason = "attempts_exceeded", until_ms = until_ms })
      Log.warn("system", ("Device %s exceeded pairing attempts; quarantined"):format(tostring(dev_id)))
    else
      send_on({ type = "JOIN_DENY", reason = "bad_code", attempts_left = left })
      Log.warn("system", ("Bad code from device %s; left=%d"):format(tostring(dev_id), left))
    end
    return
  end

  local seed = HS.build_welcome_seed(dev_id, M.code, msg.nonceW)
  send_on(seed)
  local sess = HS.derive_pair_session(M.code, dev_id, msg.nonceW, seed.nonceM, Net)
  M.sessions[dev_id] = sess

  push_pending(msg)
  local ack = Net.wrap(sess, { type="JOIN_ACK", queued=true }, { dev = dev_id })
  send_on(ack)
end

local function handle_enc_frame(frame)
  -- Try to unwrap with all sessions (we don't have dev_id in outer frame)
  for dev_id, sess in pairs(M.sessions) do
    local inner, err = Net.unwrap(sess, frame, { dev = dev_id })
    if inner then
      if inner.type == "PONG" then
        local r = M.registry[dev_id]
        if r and r.last_ping_ts then
          r.last_rtt = now() - r.last_ping_ts
          r.last_ping_ts = nil
          Log.info("pairing", ("PONG from dev=%s rtt=%dms"):format(tostring(dev_id), r.last_rtt))
        end
      elseif inner.type == "JOIN_ACK" or inner.type == "JOIN_WELCOME" then
        -- Ignore here (handled in pairing flow)
      else
        Log.info("pairing", ("ENC from dev=%s type=%s"):format(tostring(dev_id), tostring(inner.type)))
      end
      return true
    end
  end
  return false
end

local function handle_modem_message(side, channel, replyChannel, msg, dist)
  Log.info("pairing", ("RX on %s ch=%s type=%s"):format(M._modem_name or "modem", tostring(channel), (type(msg)=="table" and msg.type) or type(msg)))
  if type(msg)=="table" and msg.type=="ENC" then
    handle_enc_frame(msg)
    return
  end

  if not M.pairing_active then
    if type(msg)=="table" and msg.type=="PAIR_PROBE" and channel==M.port then
      send_on({ type = "PAIR_READY", port = M.port })
    end
    return
  end
  if not M.port or channel ~= M.port then return end
  if type(msg)=="table" then
    if msg.type == "JOIN_HELLO" then
      handle_join_hello(msg)
    elseif msg.type == "PAIR_PROBE" then
      send_on({ type="PAIR_READY", port=M.port })
    end
  end
end

function M.run()
  modem_or_error()
  print(("[JoinService] Using modem '%s' (Wireless=%s)"):format(
    M._modem_name or "?", tostring((M._modem.isWireless and M._modem.isWireless()) and true or false)
  ))
  while true do
    local t = os.startTimer(0.25)
    while true do
      local ev, p1, p2, p3, p4, p5 = os.pullEvent()
      if ev == "timer" and p1 == t then break
      elseif ev == "modem_message" then handle_modem_message(p1, p2, p3, p4, p5) end
    end

    if M.pairing_active and M.port and (now() - (M._last_ready_ms or 0) > 1000) then
      send_on({ type = "PAIR_READY", port = M.port })
      M._last_ready_ms = now()
    end

    if M.pairing_active and now() > (M.expires or 0) then
      Log.info("system", "Pairing window expired")
      M.stop_pairing()
    end
  end
end

-- Expose for UI
return {
  run = M.run,
  start_pairing_on_port = M.start_pairing_on_port,
  stop_pairing = M.stop_pairing,
  get_active_code = M.get_active_code,
  get_active_port = M.get_active_port,
  get_pending = M.get_pending,
  approve_index = M.approve_index,
  deny_index = M.deny_index,
  get_workers = M.get_workers,
  ping_worker = M.ping_worker
}