-- /storm/worker_payloads/worker_common.lua
-- Worker pairing: ask for port and 4-digit code, no discovery, heavy debug + pre-listen.

local U  = require("/storm/lib/utils")
local L  = require("/storm/lib/logger")
local HS = require("/storm/encryption/handshake")

local DEBUG = true

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

function M.find_pairing()
  local modem = modem_or_error()
  local port = read_number("Enter pairing port provided by master: ", 0, 65535)
  if not modem.isOpen(port) then pcall(function() modem.open(port) end) end
  print("[Worker] Using port " .. tostring(port) .. " for pairing.")
  return { channel = port, beacon = { cluster_id = "manual" } }
end

function M.onboard(node_kind, caps, join_info)
  local code4 = read_code4("Enter 4-digit code: ")
  local modem = modem_or_error()
  local ch = join_info.channel
  if modem.closeAll then pcall(function() modem.closeAll() end) end
  if not modem.isOpen(ch) then pcall(function() modem.open(ch) end) end
  print(("[Worker] isOpen(%d)=%s"):format(ch, tostring(modem.isOpen and modem.isOpen(ch) or false)))

  -- Pre-listen for PAIR_READY to validate connectivity (1.5s)
  local pre_t = os.startTimer(1.5)
  local saw_ready = false
  while true do
    local ev, side, channel, replyCh, msg, dist = os.pullEvent()
    if ev == "timer" and side == pre_t then
      break
    elseif ev == "modem_message" then
      local ty = (type(msg)=="table" and msg.type) or type(msg)
      if DEBUG then print(("[Worker] PRE-RX ch=%s type=%s"):format(tostring(channel), tostring(ty))) end
      if channel == ch and type(msg)=="table" and msg.type=="PAIR_READY" then
        print("[Worker] Master PAIR_READY seen. Link OK.")
        saw_ready = true
        -- don't break; continue until timer to soak noise
      end
    end
  end
  if not saw_ready then
    print("[Worker] No PAIR_READY seen. Link may be out of range or master not armed.")
  end

  local hello = HS.build_join_hello({
    node_kind = node_kind,
    device_id = os.getComputerID(),
    code = code4,
    caps = caps or {}
  })

  print(("[Worker] TX JOIN_HELLO on ch %d (dev=%s code=%s)"):format(ch, tostring(hello.device_id), tostring(hello.code)))
  modem.transmit(ch, ch, hello)

  -- Wait long enough for operator approval
  local timer = os.startTimer(60)
  while true do
    local ev, side, channel, replyCh, msg, dist = os.pullEvent()
    if ev == "timer" and side == timer then
      if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
      return false, "timeout"
    elseif ev == "modem_message" then
      if DEBUG then
        local ty = (type(msg)=="table" and msg.type) or type(msg)
        print(("[Worker] RX side=%s ch=%s reply=%s dist=%s type=%s"):format(tostring(side), tostring(channel), tostring(replyCh), tostring(dist), tostring(ty)))
      end
      if channel ~= ch then
        if DEBUG then print(("[Worker] Ignoring message on ch %s (expected %s)"):format(tostring(channel), tostring(ch))) end
      else
        if type(msg) == "table" then
          if msg.type == "JOIN_ACK" and msg.queued then
            print("[Worker] Master queued request for approval...")
            timer = os.startTimer(60)
          elseif msg.type == "JOIN_DENY" then
            if msg.reason == "quarantine" or msg.reason == "attempts_exceeded" then
              if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
              return false, msg.reason
            elseif msg.reason == "bad_code" then
              print("Bad code. Attempts left: " .. tostring(msg.attempts_left or 0))
              local c2 = read_code4("Enter 4-digit code (retry): ")
              hello.code = c2
              print("[Worker] Re-TX JOIN_HELLO with new code")
              modem.transmit(ch, ch, hello)
              timer = os.startTimer(60)
            else
              if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
              return false, "denied"
            end
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
        end
      end
    end
  end
end

return M