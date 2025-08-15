-- PATCH 2: /storm/worker_payloads/worker_common.lua
-- Fix: Close candidate channels after each scan attempt; ensure we never accumulate >128 opens.
-- Also reset modem channels at the beginning to clear any leftovers.

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
  local m = peripheral.find("modem")
  if m and m.closeAll then m.closeAll() end
end

function M.find_pairing()
  local modem = modem_or_error()

  local window_ms = 5000
  local attempts  = 0

  while attempts < 12 do
    local e = math.floor(U.now_ms() / window_ms)
    local candidates = {
      H.schedule("join_secret", "join", e-1, "global"),
      H.schedule("join_secret", "join", e,   "global"),
      H.schedule("join_secret", "join", e+1, "global")
    }

    -- Open these three channels only for this attempt
    local opened = {}
    for _, ch in ipairs(candidates) do
      if not modem.isOpen(ch) then
        pcall(function() modem.open(ch) end)
        opened[#opened+1] = ch
      else
        opened[#opened+1] = ch
      end
    end

    -- Listen briefly
    local t = os.startTimer(0.6)
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
              print("Found cluster: " .. tostring(msg.cluster_id) .. " (ch " .. tostring(ch) .. ")")
              found = { channel = ch, beacon = msg }
              break
            end
          end
          if found then break end
        end
      end
    end

    -- Close channels opened in this attempt to respect 128 limit
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

  -- Ensure only the onboarding channel is open during handshake
  if modem.closeAll then modem.closeAll() end
  if not modem.isOpen(ch) then pcall(function() modem.open(ch) end) end

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
      -- close the channel on timeout to avoid leaking open channels
      if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
      return false, "timeout"
    elseif ev == "modem_message" then
      local side, rch, replyCh, msg, dist = p1, p2, p3, p4, p5
      if rch == ch and type(msg) == "table" and msg.type == "JOIN_WELCOME" then
        -- close it now; post-onboarding we’ll open the secure session channel
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