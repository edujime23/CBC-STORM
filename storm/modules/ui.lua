-- /storm/modules/ui.lua
-- Military CMD UI: Home, Pairing, Approvals, Workers, Cannon view.
local C    = require("/storm/lib/config_loader")
local L    = require("/storm/lib/logger")
local Join = require("/storm/core/join_service")
local U    = require("/storm/lib/utils")

local M = {}
M.suspend_ticks = false

local hasColor = term.isColor and term.isColor()
local COL = {
  bg        = hasColor and colors.black   or colors.black,
  fg        = hasColor and colors.white   or colors.white,
  headerFG  = hasColor and colors.lime    or colors.white,
  bannerFG  = hasColor and colors.cyan    or colors.white,
  statusFG  = hasColor and colors.yellow  or colors.white,
  promptFG  = hasColor and colors.lime    or colors.white,
  footerFG  = hasColor and colors.white   or colors.white
}
local function setc(bg, fg) term.setBackgroundColor(bg or COL.bg); term.setTextColor(fg or COL.fg) end
local function safe_write_line(y, text, fg)
  local cx, cy = term.getCursorPos()
  local oldBG, oldFG = term.getBackgroundColor(), term.getTextColor()
  term.setCursorPos(1, y); term.setBackgroundColor(COL.bg); term.setTextColor(fg or COL.fg); term.clearLine(); if text then term.write(text) end
  term.setBackgroundColor(oldBG); term.setTextColor(oldFG); term.setCursorPos(cx, cy)
end
local function header()
  safe_write_line(1, (" SKYNET ETERNAL v4.0 | Cluster: %s | Dim: %s "):format(C.system.cluster_id or "?", C.system.dimension or "?"), COL.headerFG)
end
local function footer()
  local _, h = term.getSize()
  safe_write_line(h, "[P] Pair  [A] Approvals  [W] Workers  [C] Cannon  [Q] Quit", COL.footerFG)
end
local function pairing_info()
  if M.suspend_ticks then return end
  local code, port = Join.get_active_code(), Join.get_active_port()
  local _, h = term.getSize()
  if code and port then safe_write_line(h - 1, "Pairing ACTIVE  ::  Port: "..tostring(port).."   Code: "..tostring(code), COL.bannerFG)
  else safe_write_line(h - 1, "Pairing idle.", COL.bannerFG) end
end
local function flush_chars(ms)
  local t=os.startTimer(ms or 0.05); while true do local fired=false; parallel.waitForAny(function() local _,x=os.pullEvent("timer"); if x==t then fired=true end end,function() os.pullEvent("char") end); if fired then break end end
end
local function read_line_filtered(prompt, allowed)
  local _, h = term.getSize()
  term.setCursorPos(1, h - 1); term.clearLine()
  setc(COL.bg, COL.promptFG); term.write("> "); setc()
  term.write(prompt)
  flush_chars(0.05)
  local buf=""
  while true do
    local got_char, ch; local got_key, key
    parallel.waitForAny(
      function() local _, c = os.pullEvent("char"); got_char=true; ch=c end,
      function() local _, k = os.pullEvent("key");  got_key=true; key=k end
    )
    if got_char then if (not allowed) or allowed(ch) then buf=buf..ch; term.write(ch) end
    elseif got_key then
      if key==keys.enter then print(""); return buf
      elseif key==keys.backspace then if #buf>0 then local x,y=term.getCursorPos(); term.setCursorPos(x-1,y); term.write(" "); term.setCursorPos(x-1,y); buf=buf:sub(1,#buf-1) end
      elseif key==keys.escape then print(""); return nil end
    end
  end
end

local function redraw_home()
  term.clear(); header()
  safe_write_line(3, "HOME", COL.bannerFG)
  safe_write_line(4, "Use: [P] Pair  [A] Approvals  [W] Workers  [C] Cannon  [Q] Quit")
  footer(); pairing_info()
end

-- Pair wizard (unchanged behavior)
local function pair_wizard()
  M.suspend_ticks = true
  safe_write_line(3, "SECURE PAIRING SETUP", COL.bannerFG)
  local function allow_digits(c) return c>='0' and c<='9' end
  while true do
    local inp = read_line_filtered(" Enter secure pairing port (0-65535) [Esc cancel]: ", allow_digits)
    if not inp or inp=="" then break end
    local port=tonumber(inp)
    if not port or port<0 or port>65535 then safe_write_line(3, "Invalid port. Try again.", COL.statusFG)
    else
      local ok, err = Join.start_pairing_on_port(port)
      if ok then break
      else safe_write_line(3, err=="noisy_port" and "Port had traffic. Choose another." or ("Pairing failed: "..tostring(err)), COL.statusFG) end
    end
  end
  M.suspend_ticks=false; redraw_home()
end

local function approvals_screen()
  M.suspend_ticks = true
  term.clear(); header(); safe_write_line(3, "APPROVALS", COL.bannerFG)
  local _, h = term.getSize()
  while true do
    local list = Join.get_pending()
    for i=1,12 do
      term.setCursorPos(1, 4+i); term.clearLine()
      local rec=list[i]
      if rec then
        term.write(("[%d] id=%s  kind=%s  dev=%s  age=%ds"):format(i, rec.id, tostring(rec.hello.node_kind), tostring(rec.hello.device_id), math.floor((U.now_ms()-rec.ts)/1000)))
      end
    end
    safe_write_line(h-2, "Enter number to approve, 'dN' to deny (e.g., d1), or 'q' to exit.", COL.footerFG)
    local function allow(c) return (c>='0' and c<='9') or c=='d' or c=='D' or c=='q' or c=='Q' end
    local inp = read_line_filtered("", allow)
    if not inp or inp:lower()=="q" then break
    elseif inp:match("^%d+$") then local idx=tonumber(inp); local ok,err=Join.approve_index(idx); safe_write_line(h-3, ok and ("Approved #"..idx) or ("Approve failed: "..tostring(err)), COL.statusFG)
    elseif inp:match("^[dD]%d+$") then local idx=tonumber(inp:sub(2)); local ok,err=Join.deny_index(idx); safe_write_line(h-3, ok and ("Denied #"..idx) or ("Deny failed: "..tostring(err)), COL.statusFG) end
  end
  M.suspend_ticks=false; redraw_home()
end

-- Workers Screen (live)
local function workers_screen()
  M.suspend_ticks = true
  term.clear(); header(); safe_write_line(3, "WORKERS", COL.bannerFG)
  local w,h=term.getSize(); local top=4; local list_h=h-7; local status_y=h-3; local prompt_y=h-2
  local status_msg=""

  local function draw_list()
    local lst=Join.get_workers()
    for i=1, list_h do
      term.setCursorPos(1, top+i); term.clearLine()
      local it=lst[i]
      if it then
        local rtt=it.last_rtt and (tostring(it.last_rtt).."ms") or "n/a"
        local st =(it.status and it.status.run~=nil) and (it.status.run and "RUN" or "STOP") or "?"
        term.write(("[%d] dev=%s  modem=%s  rtt=%s  status=%s"):format(i,tostring(it.dev_id), tostring(it.modem or "?"), rtt, st))
      end
    end
  end

  local running=true; local input_buf=""

  local function prompt_draw()
    term.setCursorPos(1, prompt_y); term.clearLine()
    setc(COL.bg, COL.promptFG); term.write("> "); setc()
    term.write("pN ping | sN status | fN fire | lN log | q exit  " .. input_buf)
  end

  local function refresh_loop()
    while running do
      draw_list()
      safe_write_line(status_y, status_msg, COL.statusFG)
      footer(); pairing_info()
      prompt_draw()
      U.sleep_ms(400)
    end
  end

  local function input_loop()
    flush_chars(0.05)
    while running do
      local got_char, ch; local got_key, key
      parallel.waitForAny(
        function() local _, c = os.pullEvent("char"); got_char=true; ch=c end,
        function() local _, k = os.pullEvent("key");  got_key=true; key=k end
      )
      if got_char then input_buf=input_buf..ch; prompt_draw()
      elseif got_key then
        if key==keys.backspace then if #input_buf>0 then input_buf=input_buf:sub(1,#input_buf-1); prompt_draw() end
        elseif key==keys.enter then
          local cmd=input_buf; input_buf=""; prompt_draw()
          local lst=Join.get_workers()
          if cmd=="" then
          elseif cmd:lower()=="q" then running=false; break
          elseif cmd:match("^[pP]%d+$") then
            local idx=tonumber(cmd:sub(2)); local it=lst[idx]
            if it then local ok,err=Join.ping_worker(it.dev_id); status_msg= ok and ("Ping sent to dev="..tostring(it.dev_id)..". Waiting PONG...") or ("Ping failed: "..tostring(err))
            else status_msg="Invalid index." end
          elseif cmd:match("^[sS]%d+$") then
            local idx=tonumber(cmd:sub(2)); local it=lst[idx]
            if it then local ok,err=Join.status_worker(it.dev_id); status_msg= ok and ("Status requested from dev="..tostring(it.dev_id)..".") or ("Status failed: "..tostring(err))
            else status_msg="Invalid index." end
          elseif cmd:match("^[fF]%d+$") then
            local idx=tonumber(cmd:sub(2)); local it=lst[idx]
            if it then local ok,err=Join.fire_worker(it.dev_id,{ rounds=1 }); status_msg= ok and ("Test fire sent to dev="..tostring(it.dev_id)..".") or ("Fire failed: "..tostring(err))
            else status_msg="Invalid index." end
          elseif cmd:match("^[lL]%d+$") then
            local idx=tonumber(cmd:sub(2)); local it=lst[idx]
            if it then
              safe_write_line(status_y, "Log text (Esc cancel):", COL.statusFG)
              local any=function(_) return true end
              local msg=read_line_filtered("", any)
              if msg then local ok,err=Join.log_worker(it.dev_id, msg); status_msg= ok and ("Log sent to dev="..tostring(it.dev_id)..".") or ("Log failed: "..tostring(err))
              else status_msg="Log cancelled." end
            else status_msg="Invalid index." end
          else
            status_msg="Unknown cmd. Use pN/sN/fN/lN/q."
          end
        elseif key==keys.escape then running=false; break end
      end
    end
  end

  parallel.waitForAny(refresh_loop, input_loop)
  M.suspend_ticks=false; redraw_home()
end

-- Cannon view: aim/fire quickly
local function cannon_screen()
  M.suspend_ticks = true
  term.clear(); header(); safe_write_line(3, "CANNON", COL.bannerFG)
  local w,h=term.getSize(); local top=4; local list_h=h-7; local status_y=h-3; local prompt_y=h-2
  local status_msg=""

  local function draw_list()
    local lst=Join.get_workers()
    for i=1,list_h do
      term.setCursorPos(1, top+i); term.clearLine()
      local it=lst[i]
      if it then
        local st =(it.status and it.status.run~=nil) and (it.status.run and "RUN" or "STOP") or "?"
        local yaw= it.status and it.status.yaw or "?"
        local pitch= it.status and it.status.pitch or "?"
        term.write(("[%d] dev=%s  yaw=%s  pitch=%s  status=%s"):format(i, tostring(it.dev_id), tostring(yaw), tostring(pitch), st))
      end
    end
  end

  local running=true; local input_buf=""
  local function prompt_draw()
    term.setCursorPos(1, prompt_y); term.clearLine()
    setc(COL.bg, COL.promptFG); term.write("> "); setc()
    term.write("aN yaw pitch (aim) | fN rounds | sN status | q exit  " .. input_buf)
  end

  local function refresh_loop()
    while running do
      draw_list()
      safe_write_line(status_y, status_msg, COL.statusFG)
      footer(); pairing_info()
      prompt_draw()
      U.sleep_ms(400)
    end
  end

  local function input_loop()
    flush_chars(0.05)
    while running do
      local got_char, ch; local got_key, key
      parallel.waitForAny(
        function() local _, c=os.pullEvent("char"); got_char=true; ch=c end,
        function() local _, k=os.pullEvent("key");  got_key=true; key=k end
      )
      if got_char then input_buf=input_buf..ch; prompt_draw()
      elseif got_key then
        if key==keys.backspace then if #input_buf>0 then input_buf=input_buf:sub(1,#input_buf-1); prompt_draw() end
        elseif key==keys.enter then
          local cmd=input_buf; input_buf=""; prompt_draw()
          local lst=Join.get_workers()
          if cmd=="" then
          elseif cmd:lower()=="q" then running=false; break
          elseif cmd:match("^[aA]%d+%s+%-?%d+%.?%d*%s+%-?%d+%.?%d*$") then
            local idx, y, p = cmd:match("^[aA](%d+)%s+([%-%.%d]+)%s+([%-%.%d]+)$")
            idx=tonumber(idx); local it=lst[idx]
            if it then
              local ok,err=Join.aim_worker(it.dev_id, y, p)
              status_msg= ok and ("Aim sent to dev="..tostring(it.dev_id).." yaw="..y.." pitch="..p) or ("Aim failed: "..tostring(err))
            else status_msg="Invalid index." end
          elseif cmd:match("^[fF]%d+%s+%d+$") then
            local idx, r = cmd:match("^[fF](%d+)%s+(%d+)$")
            idx=tonumber(idx); r=tonumber(r); local it=lst[idx]
            if it then
              local ok,err=Join.fire_worker(it.dev_id, { rounds=r })
              status_msg= ok and ("Fire "..r.." rounds sent to dev="..tostring(it.dev_id)) or ("Fire failed: "..tostring(err))
            else status_msg="Invalid index." end
          elseif cmd:match("^[sS]%d+$") then
            local idx=tonumber(cmd:sub(2)); local it=lst[idx]
            if it then
              local ok,err=Join.status_worker(it.dev_id)
              status_msg= ok and ("Status requested from dev="..tostring(it.dev_id)) or ("Status failed: "..tostring(err))
            else status_msg="Invalid index." end
          else
            status_msg="Unknown cmd. Use: aN yaw pitch | fN rounds | sN | q."
          end
        elseif key==keys.escape then running=false; break end
      end
    end
  end

  parallel.waitForAny(refresh_loop, input_loop)
  M.suspend_ticks=false; redraw_home()
end

function M.run()
  redraw_home()
  local function key_loop()
    while true do
      local _, k = os.pullEvent("key")
      if k == keys.p then pair_wizard()
      elseif k == keys.a then approvals_screen()
      elseif k == keys.w then workers_screen()
      elseif k == keys.c then cannon_screen()
      elseif k == keys.q then return end
    end
  end
  local function tick_loop()
    while true do pairing_info(); U.sleep_ms(250) end
  end
  parallel.waitForAny(key_loop, tick_loop)
end

return M