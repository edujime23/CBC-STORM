-- /storm/worker_payloads/worker_common.lua
-- Worker pairing: ask for port & 4-digit code, pre-listen for PAIR_READY, encrypted ACK/WELCOME.

local U   = require("/storm/lib/utils")
local Log = require("/storm/lib/logger")
local HS  = require("/storm/encryption/handshake")
local Net = require("/storm/encryption/netsec")

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
  Log.info("worker", "Init common worker")
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

  -- Pre-listen for PAIR_READY (1.5s)
  local pre_t = os.startTimer(1.5)
  local saw_ready = false
  while true do
    local ev, side, channel, replyCh, msg, dist = os.pullEvent()
    if ev == "timer" and side == pre_t then
      break
    elseif ev == "modem_message" then
      local ty = (type(msg)=="table" and msg.type) or type(msg)
      Log.info("pairing", ("PRE-RX ch=%s type=%s"):format(tostring(channel), tostring(ty)))
      if DEBUG then print(("[Worker] PRE-RX ch=%s type=%s"):format(tostring(channel), tostring(ty))) end
      if channel == ch and type(msg)=="table" and msg.type=="PAIR_READY" then
        print("[Worker] Master PAIR_READY seen. Link OK.")
        saw_ready = true
      end
    end
  end
  if not saw_ready then
    print("[Worker] No PAIR_READY seen. Link may be out of range or master not armed.")
  end

  -- Build HELLO with nonceW+MAC(code)
  local hello = HS.build_join_hello({
    node_kind = node_kind,
    device_id = os.getComputerID(),
    code = code4,
    caps = caps or {}
  })

  print(("[Worker] TX JOIN_HELLO on ch %d (dev=%s)"):format(ch, tostring(hello.device_id)))
  modem.transmit(ch, ch, hello)

  -- Wait for WELCOME_SEED then derive session and expect encrypted ACK/WELCOME
  local nonceW = hello.nonceW
  local sess = nil
  local timer = os.startTimer(60)

  while true do
    local ev, side, channel, replyCh, msg, dist = os.pullEvent()
    if ev == "timer" and side == timer then
      if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
      return false, "timeout"
    elseif ev == "modem_message" then
      local ty = (type(msg)=="table" and msg.type) or type(msg)
      if DEBUG then print(("[Worker] RX side=%s ch=%s reply=%s dist=%s type=%s"):format(tostring(side), tostring(channel), tostring(replyCh), tostring(dist), tostring(ty))) end
      if channel ~= ch then goto continue end

      if type(msg)=="table" and msg.type=="WELCOME_SEED" then
        -- Verify mac and derive session
        local ok, err = HS.verify_welcome_seed(msg, code4, nonceW)
        if not ok then print("[Worker] Bad WELCOME_SEED MAC:"..tostring(err)); return false, "bad_seed" end
        sess = HS.derive_pair_session(code4, os.getComputerID(), nonceW, msg.nonceM, Net)
        print("[Worker] Session derived. Awaiting encrypted ACK/WELCOME...")

      elseif type(msg)=="table" and msg.type=="ENC" then
        -- Must have sess to decrypt
        if not sess then goto continue end
        local inner, err = Net.unwrap(sess, msg, { dev=os.getComputerID() })
        if not inner then
          if DEBUG then print("[Worker] ENC unwrap failed: "..tostring(err)) end
        else
          if inner.type=="JOIN_ACK" and inner.queued then
            print("[Worker] Master queued request for approval...")
            timer = os.startTimer(60)
          elseif inner.type=="JOIN_WELCOME" then
            if inner.accepted then
              if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
              M.lease = inner.lease
              M.state = "ESTABLISHED"
              print("Paired. Lease: " .. tostring(M.lease.lease_id))
              return true
            else
              if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
              return false, inner.reason or "denied"
            end
          end
        end

      elseif type(msg)=="table" and msg.type=="JOIN_DENY" then
        if msg.reason=="quarantine" or msg.reason=="attempts_exceeded" then
          if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
          return false, msg.reason
        elseif msg.reason=="bad_code" then
          print("Bad code. Attempts left: "..tostring(msg.attempts_left or 0))
          local c2 = read_code4("Enter 4-digit code (retry): ")
          -- Re-HELLO with new code
          hello = HS.build_join_hello({
            node_kind = node_kind,
            device_id = os.getComputerID(),
            code = c2,
            caps = caps or {}
          })
          nonceW = hello.nonceW
          modem.transmit(ch, ch, hello)
          timer = os.startTimer(60)
        else
          if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
          return false, "denied"
        end

      end
      ::continue::
    end
  end
end

return M