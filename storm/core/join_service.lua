-- PATCH 1: /storm/core/join_service.lua
-- Fix: Respect 128-channel limit, close old channels, and keep only 2 open (current + next).
-- Also cleanup any previous open channels on start to avoid leftover state.

local U  = require("/storm/lib/utils")
local C  = require("/storm/lib/config_loader")
local H  = require("/storm/lib/hopper")
local L  = require("/storm/lib/logger")
local HS = require("/storm/encryption/handshake")

local M = {
  pairing_active   = false,
  expires          = 0,
  code             = "",
  pending          = {},
  approved         = {},
  _modem           = nil,
  _last_beacon_ms  = 0,
  _open_set        = {}  -- [channel] = true
}

local function now() return U.now_ms() end
local function currentEpoch(window_ms) return math.floor(now() / window_ms) end

local function modem_or_error()
  if M._modem and peripheral.getName(M._modem) then return M._modem end
  local m = peripheral.find("modem")
  if not m then error("No modem found") end
  M._modem = m
  return m
end

local function safe_close_all()
  local m = modem_or_error()
  if m.closeAll then m.closeAll() end
  -- also clear our tracking
  for ch in pairs(M._open_set) do
    if m.isOpen and m.isOpen(ch) then pcall(function() m.close(ch) end) end
  end
  M._open_set = {}
end

local function set_beacon_channels(desired)
  -- desired: array of channels to keep open (max 2)
  local m = modem_or_error()
  local keep = {}
  for _, ch in ipairs(desired) do
    keep[ch] = true
    if not (M._open_set[ch]) then
      -- Open only if not already open
      if not m.isOpen(ch) then
        -- May throw if 128 already open -> we proactively close old first (below)
        pcall(function() m.open(ch) end)
      end
      M._open_set[ch] = true
    end
  end
  -- Close any channels we previously opened but are not desired now
  for ch in pairs(M._open_set) do
    if not keep[ch] then
      if m.isOpen and m.isOpen(ch) then pcall(function() m.close(ch) end) end
      M._open_set[ch] = nil
    end
  end
end

function M.start_pairing(duration_s, code)
  M.pairing_active = true
  M.expires = now() + (duration_s or 300) * 1000
  M.code = code or ("J-" .. math.random(100000, 999999))
  -- Reset modem channel state at the start of a pairing window to avoid leftovers
  safe_close_all()
  L.info("system", "Pairing window open for " .. (duration_s or 300) .. "s; code set (UI-only)")
end

function M.stop_pairing()
  M.pairing_active = false
  M.expires = 0
  M.code = ""
  -- Close all beacon channels when stopping pairing
  set_beacon_channels({})
  L.info("system", "Pairing window closed")
end

function M.get_active_code()
  if not M.pairing_active then return nil end
  return M.code
end

function M.get_pending()
  return M.pending
end

local function send_on(ch, tbl)
  local m = modem_or_error()
  m.transmit(ch, ch, tbl)
end

local function push_pending(hello, ch, side)
  local id = ("%d-%06d"):format(hello.device_id or 0, math.random(100000, 999999))
  local rec = { id = id, hello = hello, ch = ch, side = side, ts = now() }
  table.insert(M.pending, rec)
  L.info("system", ("Join request queued: %s (%s)"):format(id, tostring(hello.node_kind)))
end

function M.approve_index(i)
  local rec = M.pending[i]
  if not rec then return false, "no_pending" end
  local lease = HS.issue_lease(rec.hello, C.security.lease_ttl_ms, {
    caps = { can_fire = true, can_aim = true },
    min_cooldown_ms = (C.security.min_cooldown_ms or 3000)
  })
  send_on(rec.ch, {
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
  send_on(rec.ch, { type = "JOIN_WELCOME", accepted = false, reason = reason or "denied" })
  table.remove(M.pending, i)
  L.info("system", ("Denied join: %s"):format(rec.id))
  return true
end

local function broadcast_beacon()
  if not M.pairing_active then
    -- ensure no beacon channels are kept open when idle
    if next(M._open_set) ~= nil then set_beacon_channels({}) end
    return
  end
  if now() > M.expires then
    M.stop_pairing()
    return
  end

  -- Shared salt "global" for pairing; only 2 channels kept open (current + next epoch)
  local window = (C.network and C.network.fh_window_ms and C.network.fh_window_ms.idle) or 5000
  local e      = currentEpoch(window)
  local ch_cur = H.schedule("join_secret", "join", e,   "global")
  local ch_nxt = H.schedule("join_secret", "join", e+1, "global")

  -- Open only the required two channels; close all others we opened before
  set_beacon_channels({ ch_cur, ch_nxt })

  -- Rate-limit beaconing to avoid spam
  if now() - (M._last_beacon_ms or 0) > 500 then
    local beacon = {
      type       = "PAIR_BEACON",
      cluster_id = C.system.cluster_id,
      dimension  = C.system.dimension,
      epoch      = e,
      hint       = "enter code on worker"
    }
    send_on(ch_cur, beacon)
    send_on(ch_nxt, beacon)
    M._last_beacon_ms = now()
  end
end

local function handle_modem_message(side, ch, rch, msg, dist)
  if type(msg) ~= "table" then return end
  if msg.type == "JOIN_HELLO" then
    if not M.pairing_active then return end
    local ok, err = HS.verify_join_hello(msg, M.code)
    if not ok then
      L.warn("system", "Rejected JOIN_HELLO: " .. tostring(err))
      return
    end
    push_pending(msg, ch, side)
  end
end

function M.run()
  local m = modem_or_error()
  -- Hard reset modem channels at service start to avoid leftover 128-limit from previous runs
  if m.closeAll then m.closeAll() end
  M._open_set = {}

  while true do
    local t = os.startTimer(0.25)
    while true do
      local ev, p1, p2, p3, p4, p5 = os.pullEvent()
      if ev == "timer" and p1 == t then
        break
      elseif ev == "modem_message" then
        handle_modem_message(p1, p2, p3, p4, p5)
      end
    end
    broadcast_beacon()
  end
end

return M