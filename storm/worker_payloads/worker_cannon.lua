-- /storm/worker_payloads/worker_cannon.lua
-- Entry point: Cannon Worker — detect peripheral, pair, and get a lease (next: secure channel)

package.path = "/?.lua;/?/init.lua;" .. package.path

local Common = require("/storm/worker_payloads/worker_common")
local U = require("/storm/lib/utils")

print("CBC-STORM v4.0 — Cannon Worker")

local periph
do
  local names = { "cbc:cannonMount", "cbc:compactCannonMount", "cannonMount", "compactCannonMount" }
  for _, n in ipairs(names) do
    local list = { peripheral.find(n) }
    if #list > 0 then periph = list[1]; break end
  end
end

if not periph then
  print("No cannon peripheral found. Exiting.")
  return
end

local caps = {
  aim_support = (periph.setPitch ~= nil and periph.setYaw ~= nil),
  running = periph.isRunning and periph.isRunning() or false,
  limits = {
    elevate = periph.getMaxElevate and periph.getMaxElevate() or 0,
    depress = periph.getMaxDepress and periph.getMaxDepress() or 0
  },
  pose = {
    pitch = periph.getPitch and periph.getPitch() or 0,
    yaw = periph.getYaw and periph.getYaw() or 0
  },
  pos = {
    x = periph.getX and periph.getX() or 0,
    y = periph.getY and periph.getY() or 0,
    z = periph.getZ and periph.getZ() or 0
  },
  dir = periph.getDirection and periph.getDirection() or "unknown"
}

print("Detected cannon. Aim support:", caps.aim_support and "yes" or "no")

Common.init()
local join_info = Common.find_pairing()
if not join_info then
  print("No pairing beacon found (stealth or timeout).")
  return
end

local ok, err = Common.onboard("cannon", caps, join_info)
if not ok then
  print("Onboarding failed: " .. tostring(err))
  return
end

print("Ready to receive lease-driven commands (secure channel next phase).")