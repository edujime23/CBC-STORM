-- /storm/worker_payloads/worker_common.lua
-- Worker pairing: ask for port, then 4-digit code, no discovery.

local U  = require("/storm/lib/utils")
local L  = require("/storm/lib/logger")
local HS = require("/storm/encryption/handshake")

local M = {
  state = "CONNECTING",
  lease = nil
}

local function modem_or_error()
  local m = peripheral.find("modem")
  if not m then error("No modem found") end
  local name = peripheral.getName(m) or "modem"
  local wireless = (m.isWireless and m.isWireless()) and "true" or "false"
  print(("[Worker] Modem: %s | Wireless: %s"):format(name, wireless))
  return m
end

local function read_number(prompt, minv, maxv)
  while true do
    term.setCursorPos(1, 3); term.clearLine(); io.write(prompt)
    local s = read()
    local n = tonumber(s)
    if n and n >= minv and n <= maxv then return n end
    term.setCursorPos(1, 4); term.clearLine(); print(("Enter a number between %d and %d."):format(minv, maxv))
  end
end

local function read_code4(prompt)
  while true do
    term.setCursorPos(1, 5); term.clearLine(); io.write(prompt)
    local s = read()
    if s and s:match("^%d%d%d%d$") then return s end
    term.setCursorPos(1, 6); term.clearLine(); print("Enter exactly 4 digits (0000-9999).")
  end
end

function M.init()
  L.info("worker", "Init common worker")
  local m = peripheral.find("modem")
  if m and m.closeAll then pcall(function() m.closeAll() end) end
end

-- Return table with channel to use for onboarding
function M.find_pairing()
  local modem = modem_or_error()
  local port = read_number("Enter pairing port provided by master: ", 0, 65535)
  if not modem.isOpen(port) then pcall(function() modem.open(port) end) end
  print(("[Worker] Using port %d for pairing.").format and "" or "")
  print("[Worker] Using port " .. tostring(port) .. " for pairing.")
  return { channel = port, beacon = { cluster_id = "manual" } }
end

function M.onboard(node_kind, caps, join_info)
  local code4 = read_code4("Enter 4-digit code: ")

  local modem = modem_or_error()
  local ch = join_info.channel
  if modem.closeAll then pcall(function() modem.closeAll() end) end
  if not modem.isOpen(ch) then pcall(function() modem.open(ch) end) end

  local hello = HS.build_join_hello({
    node_kind = node_kind,
    device_id = os.getComputerID(),
    code = code4,
    caps = caps or {}
  })
  print(("[Worker] Sending JOIN_HELLO on ch %d..."):format(ch))
  modem.transmit(ch, ch, hello)

  local timer = os.startTimer(8)
  while true do
    local ev, p1, p2, p3, p4, p5 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
      return false, "timeout"
    elseif ev == "modem_message" then
      local side, rch, replyCh, msg, dist = p1, p2, p3, p4, p5
      if rch ~= ch or type(msg) ~= "table" then goto continue end

      if msg.type == "JOIN_DENY" then
        if msg.reason == "quarantine" then
          if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
          return false, "quarantine"
        elseif msg.reason == "attempts_exceeded" then
          if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
          return false, "attempts_exceeded"
        elseif msg.reason == "bad_code" then
          -- Let operator try again (one resend flow); do not close channel
          print("Bad code. Attempts left: " .. tostring(msg.attempts_left or 0))
          -- Prompt for a new code and resend once
          local c2 = read_code4("Enter 4-digit code (retry): ")
          hello.code = c2
          modem.transmit(ch, ch, hello)
          timer = os.startTimer(8)
        else
          if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
          return false, "denied"
        end

      elseif msg.type == "JOIN_ACK" and msg.queued then
        print("Request queued for approval...")

      elseif msg.type == "JOIN_WELCOME" then
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

      ::continue::
    end
  end
end

return M