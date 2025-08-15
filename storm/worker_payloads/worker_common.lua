-- /storm/worker_payloads/worker_common.lua
-- Worker common: pairing scan + onboarding (skeleton)

local U  = require("/storm/lib/utils")
local L  = require("/storm/lib/logger")
local H  = require("/storm/lib/hopper")
local HS = require("/storm/encryption/handshake")

local M = {
  state = "CONNECTING",
  lease = nil
}

local function modem_or_error()
  local m = peripheral.find("modem")
  if not m then error("No modem found") end
  return m
end

function M.init()
  L.info("worker", "Init common worker stub")
end

function M.find_pairing()
  local modem = modem_or_error()

  -- Open and scan channels for current and neighbor epochs with shared salt "global"
  local window_ms = 5000
  local attempts = 0

  while attempts < 12 do
    local e = math.floor(U.now_ms() / window_ms)
    local candidates = {
      H.schedule("join_secret", "join", e-1, "global"),
      H.schedule("join_secret", "join", e,   "global"),
      H.schedule("join_secret", "join", e+1, "global")
    }

    -- Open all candidate channels
    for _, ch in ipairs(candidates) do
      if not modem.isOpen(ch) then modem.open(ch) end
    end

    -- Listen briefly for any beacon on those channels
    local t = os.startTimer(0.5)
    while true do
      local ev, p1, p2, p3, p4, p5 = os.pullEvent()
      if ev == "timer" and p1 == t then
        break
      elseif ev == "modem_message" then
        local side, rch, replyCh, msg, dist = p1, p2, p3, p4, p5
        if type(msg) == "table" and msg.type == "PAIR_BEACON" then
          -- Accept beacons on any of the candidate channels
          for _, ch in ipairs(candidates) do
            if rch == ch then
              print("Found cluster: " .. tostring(msg.cluster_id) .. " (ch " .. tostring(ch) .. ")")
              return { channel = ch, beacon = msg }
            end
          end
        end
      end
    end

    attempts = attempts + 1
  end

  return nil
end

function M.onboard(node_kind, caps, join_info)
  term.setCursorPos(1, 5); term.clearLine()
  term.write("Enter join code: ")
  local code = read()

  local modem = modem_or_error()
  local ch = join_info.channel
  if not modem.isOpen(ch) then modem.open(ch) end

  local hello = HS.build_join_hello({
    node_kind = node_kind,
    device_id = os.getComputerID(),
    code = code,
    caps = caps or {}
  })
  modem.transmit(ch, ch, hello)

  local timer = os.startTimer(5)
  while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      return false, "timeout"
    elseif ev == "modem_message" then
      local side, rch, replyCh, msg, dist = p1, p2, p3, p4, p5
      if rch == ch and type(msg) == "table" and msg.type == "JOIN_WELCOME" then
        if msg.accepted then
          M.lease = msg.lease
          M.state = "ESTABLISHED"
          print("Paired. Lease: " .. tostring(M.lease.lease_id))
          return true
        else
          return false, msg.reason or "denied"
        end
      end
    end
  end
end

return M