-- /storm/modules/ui.lua
local C    = require("/storm/lib/config_loader")
local L    = require("/storm/lib/logger")
local Join = require("/storm/core/join_service")
local U    = require("/storm/lib/utils")

local M = {}
M.suspend_ticks = false

local function safe_write_line(y, text)
  local cx, cy = term.getCursorPos()
  local oldBG, oldFG = term.getBackgroundColor(), term.getTextColor()
  term.setCursorPos(1, y)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clearLine()
  if text then term.write(text) end
  term.setBackgroundColor(oldBG); term.setTextColor(oldFG)
  term.setCursorPos(cx, cy)
end

local function header()
  safe_write_line(1, ("SKYNET ETERNAL v4.0 | Cluster: %s | Dim: %s")
    :format(C.system.cluster_id or "?", C.system.dimension or "?"))
end

local function footer()
  local _, h = term.getSize()
  safe_write_line(h, "[P] Pair  [A] Approvals  [W] Workers  [Q] Quit")
end

local function pairing_info()
  if M.suspend_ticks then return end
  local code = Join.get_active_code()
  local port = Join.get_active_port()
  local _, h = term.getSize()
  if code and port then
    safe_write_line(h - 1, "Pairing active. Port: " .. tostring(port) .. "  Code: " .. tostring(code))
  else
    safe_write_line(h - 1, "Pairing idle.")
  end
end

local function flush_chars(ms)
  local duration = (ms or 0.05)
  local timer = os.startTimer(duration)
  while true do
    local fired = false
    parallel.waitForAny(
      function() local _, t = os.pullEvent("timer"); if t == timer then fired = true end end,
      function() os.pullEvent("char") end
    )
    if fired then break end
  end
end

local function read_line_filtered(prompt, allowed)
  local _, h = term.getSize()
  term.setCursorPos(1, h - 1); term.clearLine(); term.write(prompt)
  flush_chars(0.05)
  local buf = ""
  while true do
    local got_char, ch
    local got_key, key
    parallel.waitForAny(
      function() local _, c = os.pullEvent("char"); got_char = true; ch = c end,
      function() local _, k = os.pullEvent("key");  got_key  = true; key = k end
    )
    if got_char then
      if (not allowed) or allowed(ch) then buf = buf .. ch; term.write(ch) end
    elseif got_key then
      if key == keys.enter then print(""); return buf
      elseif key == keys.backspace then
        if #buf > 0 then local x,y=term.getCursorPos(); term.setCursorPos(x-1,y); term.write(" "); term.setCursorPos(x-1,y); buf=buf:sub(1,#buf-1) end
      elseif key == keys.escape then print(""); return nil end
    end
  end
end

local function redraw_all()
  term.clear()
  header()
  safe_write_line(3, "Home: [P] Pair  [A] Approvals  [W] Workers  [Q] Quit")
  footer()
  pairing_info()
end

local function pair_wizard()
  M.suspend_ticks = true
  safe_write_line(3, "SECURE PAIRING SETUP")
  local function allow_digits(c) return c >= '0' and c <= '9' end
  while true do
    local inp = read_line_filtered("Enter secure pairing port (0-65535) [Esc cancel]: ", allow_digits)
    if not inp or inp == "" then break end
    local port = tonumber(inp)
    if not port or port < 0 or port > 65535 then safe_write_line(3, "Invalid port. Try again.")
    else
      local ok, err = Join.start_pairing_on_port(port)
      if ok then break
      else safe_write_line(3, err=="noisy_port" and "Port had traffic. Choose another." or ("Pairing failed: "..tostring(err))) end
    end
  end
  M.suspend_ticks = false
  redraw_all()
end

local function approvals_screen()
  M.suspend_ticks = true
  term.clear(); header()
  local _, h = term.getSize()
  while true do
    local list = Join.get_pending()
    term.setCursorPos(1, 3); term.clearLine(); term.write("Pending join requests:")
    for i = 1, math.max(10, #list) do
      term.setCursorPos(1, 3 + i); term.clearLine()
      local rec = list[i]
      if rec then
        term.write(("[%d] id=%s  kind=%s  dev=%s  age=%ds"):format(
          i, rec.id, tostring(rec.hello.node_kind), tostring(rec.hello.device_id),
          math.floor((U.now_ms() - rec.ts) / 1000)))
      end
    end
    if #list == 0 then
      safe_write_line(h - 2, "No pending join requests. Press ESC or 'q' to return.")
      local function allow_empty(c) return c=='q' or c=='Q' end
      local inp = read_line_filtered("> ", allow_empty)
      if inp == nil or inp:lower() == 'q' then break end
    else
      safe_write_line(h - 2, "Enter number to approve, 'dN' to deny (e.g., d1), or 'q' to exit.")
      local function allow_approvals_char(c) return (c >= '0' and c <= '9') or c=='d' or c=='D' or c=='q' or c=='Q' end
      local inp = read_line_filtered("> ", allow_approvals_char)
      if not inp then break
      elseif inp == "" then
      elseif inp:lower() == "q" then break
      elseif inp:match("^%d+$") then
        local idx = tonumber(inp)
        local ok, err = Join.approve_index(idx)
        safe_write_line(h - 3, ok and ("Approved #"..idx) or ("Approve failed: "..tostring(err)))
      elseif inp:match("^[dD]%d+$") then
        local idx = tonumber(inp:sub(2))
        local ok, err = Join.deny_index(idx)
        safe_write_line(h - 3, ok and ("Denied #"..idx) or ("Deny failed: "..tostring(err)))
      end
    end
  end
  M.suspend_ticks = false
  redraw_all()
end

local function workers_screen()
  M.suspend_ticks = true
  term.clear(); header()
  local _, h = term.getSize()
  while true do
    local list = Join.get_workers()
    term.setCursorPos(1, 3); term.clearLine(); term.write("Workers:")
    for i = 1, math.max(10, #list) do
      term.setCursorPos(1, 3 + i); term.clearLine()
      local w = list[i]
      if w then
        local rtt = w.last_rtt and (tostring(w.last_rtt).."ms") or "n/a"
        local st  = w.status and (w.status.run and "RUN" or "STOP") or "?"
        term.write(("[%d] dev=%s  modem=%s  rtt=%s  status=%s"):format(
          i, tostring(w.dev_id), tostring(w.modem or "?"), rtt, st))
      end
    end
    safe_write_line(h - 2, "Type: pN ping | sN status | fN test fire | lN log | q exit.")
    local function allow_workers_char(c) return (c >= '0' and c <= '9') or c=='p' or c=='P' or c=='s' or c=='S' or c=='f' or c=='F' or c=='l' or c=='L' or c=='q' or c=='Q' end
    local inp = read_line_filtered("> ", allow_workers_char)
    if not inp or inp:lower()=="q" then break end
    if inp:match("^[pP]%d+$") then
      local idx = tonumber(inp:sub(2)); local w = list[idx]
      safe_write_line(h - 3, (w and Join.ping_worker(w.dev_id)) and ("Ping sent to dev="..tostring(w.dev_id)) or "Ping failed/invalid index.")
    elseif inp:match("^[sS]%d+$") then
      local idx = tonumber(inp:sub(2)); local w = list[idx]
      safe_write_line(h - 3, (w and Join.status_worker(w.dev_id)) and ("Status requested from dev="..tostring(w.dev_id)) or "Status failed/invalid index.")
    elseif inp:match("^[fF]%d+$") then
      local idx = tonumber(inp:sub(2)); local w = list[idx]
      safe_write_line(h - 3, (w and Join.fire_worker(w.dev_id, { rounds=1 })) and ("Test fire sent to dev="..tostring(w.dev_id)) or "Fire failed/invalid index.")
    elseif inp:match("^[lL]%d+$") then
      local idx = tonumber(inp:sub(2)); local w = list[idx]
      if w then
        local any = function(_) return true end
        local msg = read_line_filtered("Log text: ", any)
        safe_write_line(h - 3, (Join.log_worker(w.dev_id, msg or "")) and ("Log sent to dev="..tostring(w.dev_id)) or "Log failed.")
      else
        safe_write_line(h - 3, "Invalid index.")
      end
    end
  end
  M.suspend_ticks = false
  redraw_all()
end

function M.run()
  redraw_all()
  local function key_loop()
    while true do
      local _, k = os.pullEvent("key")
      if k == keys.p then pair_wizard()
      elseif k == keys.a then approvals_screen()
      elseif k == keys.w then workers_screen()
      elseif k == keys.q then return end
    end
  end
  local function tick_loop()
    while true do pairing_info(); U.sleep_ms(250) end
  end
  parallel.waitForAny(key_loop, tick_loop)
end

return M