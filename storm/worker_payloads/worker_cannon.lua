-- /storm/worker_payloads/worker_cannon.lua
local Common = require("/storm/worker_payloads/worker_common")
local Net    = require("/storm/encryption/netsec")
local U      = require("/storm/lib/utils")

print("CBC-STORM v4.0 — Cannon Worker")

local periph
do
  local names = { "cbc:cannonMount", "cbc:compactCannonMount", "cbc_cannon_mount", "cbc_compact_cannon_mount" }
  for _, n in ipairs(names) do
    local list = { peripheral.find(n) }
    if #list > 0 then periph = list[1]; break end
  end
end
if not periph then print("No cannon peripheral found. Exiting."); return end

local caps = {
  aim_support = (periph.setPitch ~= nil and periph.setYaw ~= nil),
  running = periph.isRunning and periph.isRunning() or false,
  limits = {
    elevate = periph.getMaxElevate and periph.getMaxElevate() or 0,
    depress = periph.getMaxDepress and periph.getMaxDepress() or 0
  }
}

print("Detected cannon. Aim support:", caps.aim_support and "yes" or "no")

Common.init()
local join_info = Common.find_pairing(); if not join_info then print("Pairing cancelled."); return end
local ok, err = Common.onboard("cannon", { aim_support=caps.aim_support }, join_info)
if not ok then print("Onboarding failed: "..tostring(err)); return end

-- Cannon service loop
local last_fire_ms = 0
local MIN_COOLDOWN = 3000

local function clamp_pitch(p)
  local lim = caps.limits
  return math.max(-(lim.depress or 0), math.min(lim.elevate or 0, p))
end

local function status_payload(extra)
  local pitch = periph.getPitch and periph.getPitch() or 0
  local yaw   = periph.getYaw and periph.getYaw() or 0
  local run   = periph.isRunning and periph.isRunning() or false
  local st = { type="CANNON_STATUS", run=run, pitch=pitch, yaw=yaw, ts=U.now_ms() }
  if extra then for k,v in pairs(extra) do st[k]=v end end
  return st
end

local function aim_to(yaw, pitch)
  if not caps.aim_support then return false, "no_aim_support" end
  local y = (tonumber(yaw) or 0) % 360
  local p = clamp_pitch(tonumber(pitch) or 0)
  if periph.setYaw then periph.setYaw(y) end
  if periph.setPitch then periph.setPitch(p) end
  return true
end

local function handle_fire(args)
  local now_ms = U.now_ms()
  local ttl = args.ttl_ms or 10000
  local when = args.when_ms or now_ms
  if now_ms > when + ttl then return false, "ttl_expired" end
  local since = now_ms - last_fire_ms
  if since < MIN_COOLDOWN then return false, "cooldown" end
  if periph.isRunning and not periph.isRunning() and periph.assemble then periph.assemble() end
  if args.aim and caps.aim_support then aim_to(args.aim.yaw, args.aim.pitch) end
  if when > now_ms then sleep((when - now_ms)/1000) end
  local rounds = math.max(1, tonumber(args.rounds or 1))
  for i=1, rounds do if periph.fire then periph.fire() end; if rounds>1 then sleep(0.2) end end
  last_fire_ms = U.now_ms()
  return true
end

local session, ch = Common.session, Common.channel
local modem = peripheral.find("modem")

print("Ready to receive lease-driven commands (encrypted session established).")
print("[Worker] Entering service loop on channel "..tostring(ch).." (encrypted).")

while true do
  local ev, side, channel, reply, msg, dist = os.pullEvent()
  if ev=="modem_message" and channel==ch and type(msg)=="table" and msg.type=="ENC" then
    local inner, err = Net.unwrap(session, msg, { dev=os.getComputerID() })
    if inner then
      if inner.type == "PING" then
        modem.transmit(ch, ch, Net.wrap(session, { type="PONG", ts=U.now_ms() }, { dev=os.getComputerID() }))
      elseif inner.type == "STATUS" then
        modem.transmit(ch, ch, Net.wrap(session, status_payload(), { dev=os.getComputerID() }))
      elseif inner.type == "LOG" then
        print("[Worker] LOG from master: "..tostring(inner.msg))
      elseif inner.type == "AIM" then
        local okA, aErr = aim_to(inner.aim and inner.aim.yaw, inner.aim and inner.aim.pitch)
        modem.transmit(ch, ch, Net.wrap(session, status_payload({ result = okA and "ok" or ("error:"..tostring(aErr)) }), { dev=os.getComputerID() }))
      elseif inner.type == "FIRE" then
        local okF, fErr = handle_fire(inner)
        modem.transmit(ch, ch, Net.wrap(session, status_payload({ result = okF and "ok" or ("error:"..tostring(fErr)) }), { dev=os.getComputerID() }))
      elseif inner.type == "SHUTDOWN" then
        print("[Worker] SHUTDOWN received."); break
      end
    end
  end
end
if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end