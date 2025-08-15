-- /storm/worker_payloads/worker_common.lua
-- Worker common: pairing scan + onboarding with channel limit, fallback, and debug

local U  = require("/storm/lib/utils")
local L  = require("/storm/lib/logger")
local H  = require("/storm/lib/hopper")
local HS = require("/storm/encryption/handshake")

local M = {
  state = "CONNECTING",
  lease = nil
}

local PAIR_FALLBACK_CH = 54545

local function modem_or_error()
  local m = peripheral.find("modem")
  if not m then error("No modem found") end
  local name = peripheral.getName(m) or "modem"
  print(("[Worker] Modem: %s | Wireless: %s"):format(name, tostring(m.isWireless and m.isWireless() or "unknown")))
  return m
end

function M.init()
  L.info("worker", "Init common worker stub")
  local m = peripheral.find("modem")
  if m and m.closeAll then pcall(function() m.closeAll() end) end
end

function M.find_pairing()
  local modem = modem_or_error()

  local window_ms = 5000
  local attempts  = 0

  while attempts < 12 do
    local e = math.floor(U.now_ms() / window_ms)
    local c1 = H.schedule("join_secret", "join", e-1, "global")
    local c2 = H.schedule("join_secret", "join", e,   "global")
    local c3 = H.schedule("join_secret", "join", e+1, "global")
    local candidates = { c1, c2, c3, PAIR_FALLBACK_CH }

    print(("[Worker] Scanning channels: %d, %d, %d, %d"):format(c1, c2, c3, PAIR_FALLBACK_CH))

    -- Open these channels for this attempt
    local opened = {}
    for _, ch in ipairs(candidates) do
      if not modem.isOpen(ch) then
        pcall(function() modem.open(ch) end)
      end
      opened[#opened+1] = ch
    end

    -- Listen briefly
    local t = os.startTimer(0.8)
    local found = nil
    while true do
      local ev, p1, p2, p3, p4, p5 = os.pullEvent()
      if ev == "timer" and p1 == t then
        break
      elseif ev == "modem_message" then
        local side, rch, replyCh, msg, dist = p1, p2, p3, p4, p5
        if type(msg) == "table" and msg.type == "PAIR_BEACON" then
          for _, ch in ipairs(candidates) do
            if rch == ch then
              print(("[Worker] Found beacon on ch %d from cluster %s"):format(ch, tostring(msg.cluster_id)))
              found = { channel = ch, beacon = msg }
              break
            end
          end
          if found then break end
        end
      end
    end

    -- Close channels opened in this attempt
    for _, ch in ipairs(opened) do
      if modem.isOpen and modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
    end

    if found then return found end

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

  if modem.closeAll then pcall(function() modem.closeAll() end) end
  if not modem.isOpen(ch) then pcall(function() modem.open(ch) end) end

  local hello = HS.build_join_hello({
    node_kind = node_kind,
    device_id = os.getComputerID(),
    code = code,
    caps = caps or {}
  })
  print(("[Worker] Sending JOIN_HELLO on ch %d"):format(ch))
  modem.transmit(ch, ch, hello)

  local timer = os.startTimer(5)
  while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
      return false, "timeout"
    elseif ev == "modem_message" then
      local side, rch, replyCh, msg, dist = p1, p2, p3, p4, p5
      if rch == ch and type(msg) == "table" and msg.type == "JOIN_WELCOME" then
        if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
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