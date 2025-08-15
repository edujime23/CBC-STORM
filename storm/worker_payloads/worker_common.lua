-- /storm/worker_payloads/worker_common.lua
-- Worker pairing with PAIR_PROBE fallback + encrypted ACK/WELCOME + main loop.

local U   = require("/storm/lib/utils")
local Log = require("/storm/lib/logger")
local HS  = require("/storm/encryption/handshake")
local Net = require("/storm/encryption/netsec")

local M = {
  state   = "CONNECTING",
  lease   = nil,
  _modem  = nil,
  _name   = nil,
  session = nil,
  channel = nil
}

local function pick_wireless_modem()
  local names = peripheral.getNames()
  local first_modem = nil
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      if m then
        local isW = (m.isWireless and m.isWireless()) and true or false
        if isW then
          M._modem, M._name = m, name
          print(("[Worker] Using wireless modem '%s'"):format(name))
          return m
        end
        if not first_modem then first_modem = { obj=m, name=name } end
      end
    end
  end
  if first_modem then
    error(("No wireless modem found. Found only wired modem '%s'. Attach a wireless/ender modem."):format(first_modem.name))
  else
    error("No modem found. Attach a wireless modem.")
  end
end

local function modem_or_error()
  if M._modem and peripheral.getName(M._modem) then return M._modem end
  return pick_wireless_modem()
end

local function read_number(prompt, minv, maxv)
  while true do
    local _, h = term.getSize()
    term.setCursorPos(1, h-1); term.clearLine(); io.write(prompt)
    local s = read()
    local n = tonumber(s)
    if n and n >= minv and n <= maxv then return n end
    term.setCursorPos(1, h-2); term.clearLine(); print(("Enter a number between %d and %d."):format(minv, maxv))
  end
end

local function read_code4(prompt)
  while true do
    local _, h = term.getSize()
    term.setCursorPos(1, h-1); term.clearLine(); io.write(prompt)
    local s = read()
    if s and s:match("^%d%d%d%d$") then return s end
    term.setCursorPos(1, h-2); term.clearLine(); print("Enter exactly 4 digits (0000-9999).")
  end
end

function M.init()
  Log.info("worker", "Init common worker")
  local m = peripheral.find("modem")
  if m and m.closeAll then pcall(function() m.closeAll() end) end
  modem_or_error() -- ensure wireless modem
end

function M.find_pairing()
  local modem = modem_or_error()
  local port = read_number("Enter pairing port provided by master: ", 0, 65535)
  if not modem.isOpen(port) then pcall(function() modem.open(port) end) end
  print(("[Worker] Using modem '%s' on port %d for pairing."):format(M._name or "modem", port))
  return { channel = port, beacon = { cluster_id = "manual" } }
end

function M.onboard(node_kind, caps, join_info)
  local code4 = read_code4("Enter 4-digit code: ")
  local modem = modem_or_error()
  local ch = join_info.channel
  if modem.closeAll then pcall(function() modem.closeAll() end) end
  if not modem.isOpen(ch) then pcall(function() modem.open(ch) end) end
  print(("[Worker] isOpen(%d)=%s"):format(ch, tostring(modem.isOpen and modem.isOpen(ch) or false)))

  local function listen_for_ready(timeout_s)
    local t = os.startTimer(timeout_s or 1.0)
    while true do
      local ev, side, channel, reply, msg, dist = os.pullEvent()
      if ev=="timer" and side==t then return false end
      if ev=="modem_message" and channel==ch and type(msg)=="table" and msg.type=="PAIR_READY" then
        print("[Worker] Master PAIR_READY seen.")
        return true
      end
    end
  end

  local saw_ready = listen_for_ready(1.0)
  if not saw_ready then
    for i=1,3 do modem.transmit(ch, ch, { type="PAIR_PROBE", dev=os.getComputerID() }); U.sleep_ms(100) end
    saw_ready = listen_for_ready(1.0)
    if not saw_ready then print("[Worker] No PAIR_READY seen. Continuing anyway.") end
  end

  local hello = HS.build_join_hello({
    node_kind = node_kind,
    device_id = os.getComputerID(),
    code = code4,
    caps = caps or {}
  })

  print(("[Worker] TX JOIN_HELLO on ch %d (dev=%s)"):format(ch, tostring(hello.device_id)))
  modem.transmit(ch, ch, hello)

  local nonceW = hello.nonceW
  local sess = nil
  local timer = os.startTimer(60)

  while true do
    local ev, side, channel, replyCh, msg, dist = os.pullEvent()
    if ev == "timer" and side == timer then
      if modem.isOpen(ch) then pcall(function() modem.close(ch) end) end
      return false, "timeout"
    elseif ev == "modem_message" then
      if channel ~= ch then goto continue end
      if type(msg)=="table" and msg.type=="WELCOME_SEED" then
        local ok, err = HS.verify_welcome_seed(msg, code4, nonceW)
        if not ok then print("[Worker] Bad WELCOME_SEED MAC:"..tostring(err)); return false, "bad_seed" end
        sess = HS.derive_pair_session(code4, os.getComputerID(), nonceW, msg.nonceM, Net)
        print("[Worker] Session derived; awaiting encrypted ACK/WELCOME.")
      elseif type(msg)=="table" and msg.type=="ENC" and sess then
        local inner, err = Net.unwrap(sess, msg, { dev=os.getComputerID() })
        if inner then
          if inner.type=="JOIN_ACK" and inner.queued then
            print("[Worker] Master queued request for approval...")
            timer = os.startTimer(60)
          elseif inner.type=="JOIN_WELCOME" then
            if inner.accepted then
              -- Keep channel open for further encrypted commands
              M.lease   = inner.lease
              M.state   = "ESTABLISHED"
              M.session = sess
              M.channel = ch
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
          print("Bad code. Attempts left: " .. tostring(msg.attempts_left or 0))
          local c2 = read_code4("Enter 4-digit code (retry): ")
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

-- Service loop: stay alive and handle encrypted commands
function M.run_service()
  if not (M.session and M.channel) then
    print("[Worker] No session/channel; nothing to do.")
    return
  end
  local modem = modem_or_error()
  print("[Worker] Entering service loop on channel "..tostring(M.channel).." (encrypted).")
  while true do
    local ev, side, ch, reply, msg, dist = os.pullEvent()
    if ev == "modem_message" and ch == M.channel and type(msg)=="table" and msg.type=="ENC" then
      local inner, err = Net.unwrap(M.session, msg, { dev=os.getComputerID() })
      if inner then
        if inner.type == "PING" then
          local resp = Net.wrap(M.session, { type="PONG", ts=U.now_ms() }, { dev=os.getComputerID() })
          modem.transmit(M.channel, M.channel, resp)
        elseif inner.type == "SHUTDOWN" then
          print("[Worker] SHUTDOWN received.")
          break
        elseif inner.type == "LOG" then
          print("[Worker] LOG: "..tostring(inner.msg))
        end
      end
    end
  end
  if modem.isOpen(M.channel) then pcall(function() modem.close(M.channel) end) end
end

return M