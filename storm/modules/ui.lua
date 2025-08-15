-- /storm/modules/ui.lua
-- Remastered military CMD UI: no overflow, no strange chars, cursor-safe, hotkey-safe.
-- Views: Home, Pairing wizard, Approvals, Workers (live), Cannon (group control).

local C    = require("/storm/lib/config_loader")
local L    = require("/storm/lib/logger")
local Join = require("/storm/core/join_service")
local U    = require("/storm/lib/utils")

local M = {}
M.suspend_ticks = false

-- Custom renderer with box-drawing and safe clipping
local R = {}
do
  local hasColor = term.isColor and term.isColor()
  M.COL = {
    bg        = hasColor and colors.black   or colors.black,
    fg        = hasColor and colors.white   or colors.white,
    headerFG  = hasColor and colors.lime    or colors.white,
    bannerFG  = hasColor and colors.cyan    or colors.white,
    statusFG  = hasColor and colors.yellow  or colors.white,
    promptFG  = hasColor and colors.lime    or colors.white,
    footerFG  = hasColor and colors.white   or colors.white
  }

  function R.setc(bg, fg) term.setBackgroundColor(bg or M.COL.bg); term.setTextColor(fg or M.COL.fg) end

  function R.clip(s, w)
    if not s then return "" end
    if #s > w then return s:sub(1, w-1) .. "…" end
    return s
  end

  function R.draw(x, y, text, fg)
    local cx, cy = term.getCursorPos()
    local oldBG, oldFG = term.getBackgroundColor(), term.getTextColor()
    term.setCursorPos(x, y); R.setc(M.COL.bg, fg or M.COL.fg); term.clearLine(); if text then term.write(text) end
    term.setBackgroundColor(oldBG); term.setTextColor(oldFG); term.setCursorPos(cx, cy)
  end

  function R.header()
    local w,_ = term.getSize()
    local line = (" SKYNET ETERNAL v4.0 | Cluster: %s | Dim: %s "):format(C.system.cluster_id or "?", C.system.dimension or "?")
    R.draw(1, 1, R.clip(line, w), M.COL.headerFG)
  end

  function R.footer()
    local w,h = term.getSize()
    R.draw(1, h, R.clip("[P] Pair  [A] Approvals  [W] Workers  [C] Cannon  [Q] Quit", w), M.COL.footerFG)
  end

  function R.pairing_info()
    if M.suspend_ticks then return end
    local code, port = Join.get_active_code(), Join.get_active_port()
    local w,h = term.getSize()
    if code and port then
      R.draw(1, h-1, R.clip("Pairing ACTIVE :: Port: "..tostring(port).."  Code: "..tostring(code), w), M.COL.bannerFG)
    else
      R.draw(1, h-1, R.clip("Pairing idle.", w), M.COL.bannerFG)
    end
  end

  local function flush_chars(ms)
    local t=os.startTimer(ms or 0.05); while true do local fired=false; parallel.waitForAny(function() local _,x=os.pullEvent("timer"); if x==t then fired=true end end,function() os.pullEvent("char") end); if fired then break end end
  end

  function R.read_line(prompt, allowed)
    local w,h = term.getSize()
    R.draw(1, h-2, R.clip(prompt, w), M.COL.statusFG)
    term.setCursorPos(1, h-1); term.clearLine()
    R.setc(M.COL.bg, M.COL.promptFG); term.write("> "); R.setc()
    flush_chars(0.05)
    local buf = ""
    while true do
      local got_char, ch; local got_key, key
      parallel.waitForAny(
        function() local _, c = os.pullEvent("char"); got_char=true; ch=c end,
        function() local _, k = os.pullEvent("key");  got_key=true; key=k end
      )
      if got_char then
        if (not allowed) or allowed(ch) then
          if #buf < w - 4 then
            buf = buf .. ch; term.write(ch)
          end
        end
      elseif got_key then
        if key==keys.enter then print(""); return buf
        elseif key==keys.backspace then if #buf>0 then local x,y=term.getCursorPos(); term.setCursorPos(x-1,y); term.write(" "); term.setCursorPos(x-1,y); buf=buf:sub(1,#buf-1) end
        elseif key==keys.escape then print(""); return nil end
      end
    end
  end
end

-- This function was missing from the R block in the previous version. It's now defined globally for all UI screens.
local function safe_write_line(y, text, fg)
    R.draw(1, y, text, fg)
end

local function redraw_home()
  term.clear()
  R.header()
  R.draw(1, 3, "HOME", M.COL.bannerFG)
  R.draw(1, 4, "Use: [P] Pair  [A] Approvals  [W] Workers  [C] Cannon  [Q] Quit")
  R.footer()
  R.pairing_info()
end

local function pair_wizard()
  M.suspend_ticks = true
  R.draw(1, 3, "SECURE PAIRING SETUP", M.COL.bannerFG)
  local function allow_digits(c) return c>='0' and c<='9' end
  while true do
    local inp = R.read_line("Enter secure pairing port (0-65535) [Esc cancel]: ", allow_digits)
    if not inp or inp=="" then break end
    local port = tonumber(inp)
    if not port or port<0 or port>65535 then R.draw(1, 3, "Invalid port. Try again.", M.COL.statusFG)
    else
      local ok, err = Join.start_pairing_on_port(port)
      if ok then break
      else R.draw(1, 3, err=="noisy_port" and "Port had traffic. Choose another." or ("Pairing failed: "..tostring(err)), M.COL.statusFG) end
    end
  end
  M.suspend_ticks=false
  redraw_home()
end

local function approvals_screen()
  M.suspend_ticks = true
  term.clear(); R.header()
  R.draw(1, 3, "APPROVALS", M.COL.bannerFG)
  local w,h=term.getSize(); local top=4; local list_h=h-7
  while true do
    local list = Join.get_pending()
    for i=1,list_h do
      term.setCursorPos(1, top+i); term.clearLine()
      local rec=list[i]
      if rec then
        term.write(R.clip(("[%d] id=%s  kind=%s  dev=%s  age=%ds"):format(
          i, rec.id, tostring(rec.hello.node_kind), tostring(rec.hello.device_id),
          math.floor((U.now_ms()-rec.ts)/1000)), w))
      end
    end
    local instruction = #list==0 and "No pending requests. Press ESC or 'q' to return."
                                 or "Enter N approve | dN deny | q exit."
    local function allow(c) return (c>='0' and c<='9') or c=='d' or c=='D' or c=='q' or c=='Q' end
    local inp = R.read_line(instruction, allow)
    if not inp or inp:lower()=="q" then break
    elseif inp:match("^%d+$") then
      local idx=tonumber(inp); local ok,err=Join.approve_index(idx)
      safe_write_line(h-4, ok and ("Approved #"..idx) or ("Approve failed: "..tostring(err)), M.COL.statusFG)
    elseif inp:match("^[dD]%d+$") then
      local idx=tonumber(inp:sub(2)); local ok,err=Join.deny_index(idx)
      safe_write_line(h-4, ok and ("Denied #"..idx) or ("Deny failed: "..tostring(err)), M.COL.statusFG)
    end
  end
  M.suspend_ticks=false
  redraw_home()
end

local function workers_screen()
  M.suspend_ticks = true
  term.clear(); R.header(); R.draw(1, 3, "WORKERS", M.COL.bannerFG)
  local w,h=term.getSize(); local top=4; local list_h=h-7
  local running=true
  local function redraw()
    local lst=Join.get_workers()
    for i=1, list_h do
      term.setCursorPos(1, top+i); term.clearLine()
      local it=lst[i]
      if it then
        local rtt=it.last_rtt and (tostring(it.last_rtt).."ms") or "n/a"
        local st =(it.status and it.status.run~=nil) and (it.status.run and "RUN" or "STOP") or "?"
        term.write(R.clip(("[%d] dev=%s  modem=%s  rtt=%s  status=%s"):format(
          i, tostring(it.dev_id), tostring(it.modem or "?"), rtt, st), w))
      end
    end
    R.footer(); R.pairing_info()
  end

  parallel.waitForAny(
    function() while running do redraw(); U.sleep_ms(400) end end,
    function()
      while running do
        local lst=Join.get_workers()
        local inp = R.read_line("pN ping | sN status | fN fire | lN log | q exit", nil)
        if not inp or inp:lower()=="q" then running=false; break end
        if inp:match("^[pP]%d+$") then local idx=tonumber(inp:sub(2)); local it=lst[idx]; if it then Join.ping_worker(it.dev_id) end
        elseif inp:match("^[sS]%d+$") then local idx=tonumber(inp:sub(2)); local it=lst[idx]; if it then Join.status_worker(it.dev_id) end
        elseif inp:match("^[fF]%d+$") then local idx=tonumber(inp:sub(2)); local it=lst[idx]; if it then Join.fire_worker(it.dev_id,{ rounds=1 }) end
        elseif inp:match("^[lL]%d+$") then local idx=tonumber(inp:sub(2)); local it=lst[idx]; if it then local msg=R.read_line("Log text (Esc cancel):", nil); if msg then Join.log_worker(it.dev_id, msg) end end end
      end
    end
  )
  M.suspend_ticks=false; redraw_home()
end

local function cannon_screen()
  M.suspend_ticks=true; term.clear(); R.header(); R.draw(1, 3, "CANNON", M.COL.bannerFG)
  local w,h=term.getSize(); local top=4; local list_h=h-8; local selected={}

  local function draw()
    local lst=Join.get_workers()
    for i=1,list_h do
      term.setCursorPos(1, top+i); term.clearLine()
      local it=lst[i]
      if it then
        local sel=selected[it.dev_id] and "*" or " "
        local yaw=it.status and tostring(it.status.yaw) or "?"
        local pitch=it.status and tostring(it.status.pitch) or "?"
        term.write(R.clip(("["..sel.."] %d dev=%s yaw=%s pitch=%s"):format(i,tostring(it.dev_id),yaw,pitch),w))
      end
    end
    R.footer(); R.pairing_info()
  end

  local running=true
  parallel.waitForAny(
    function() while running do draw(); U.sleep_ms(400) end end,
    function()
      while running do
        local lst=Join.get_workers()
        local inp = R.read_line("tN | ls | a YAW PITCH | f ROUNDS | spread d ROUNDS | sN | q", nil)
        if not inp or inp:lower()=="q" then running=false; break end
        if inp:match("^[tT]%d+$") then local idx=tonumber(inp:sub(2)); local it=lst[idx]; if it then if selected[it.dev_id] then selected[it.dev_id]=nil else selected[it.dev_id]=true end end
        elseif inp:match("^[aA]%s+%-?%d+%.?%d*%s+%-?%d+%.?%d*$") then
          local y,p=inp:match("^[aA]%s+([%-%.%d]+)%s+([%-%.%d]+)$")
          if y and p then for dev,_ in pairs(selected) do Join.aim_worker(dev,y,p) end end
        elseif inp:match("^[fF]%s+%d+$") then
          local r=tonumber(inp:match("%d+"))
          if r then for dev,_ in pairs(selected) do Join.fire_worker(dev,{rounds=r}) end end
        elseif inp:match("^[sS]pread%s+%-?%d+%.?%d*%s+%d+$") then
          local d,r=inp:match("^[sS]pread%s+([%-%.%d]+)%s+(%d+)$")
          d=tonumber(d); r=tonumber(r)
          if d and r then
            local selList={}; for dev,_ in pairs(selected) do selList[#selList+1]=dev end
            table.sort(selList)
            for i,dev in ipairs(selList) do
              local offset=(i-(#selList+1)/2)*d
              local wkr=nil; for j=1,#lst do if lst[j].dev_id==dev then wkr=lst[j] end end
              local yaw=(wkr and wkr.status and wkr.status.yaw) or 0
              Join.aim_worker(dev, yaw+offset, (wkr and wkr.status and wkr.status.pitch) or 0)
              Join.fire_worker(dev, { rounds=r })
            end
          end
        elseif inp:match("^[sS]%d+$") then local idx=tonumber(inp:sub(2)); local it=lst[idx]; if it then Join.status_worker(it.dev_id) end end
      end
    end
  )
  M.suspend_ticks=false; redraw_home()
end

function M.run()
  redraw_home()
  local function key_loop()
    while true do
      local _, k = os.pullEvent("key")
      if k==keys.p then pair_wizard()
      elseif k==keys.a then approvals_screen()
      elseif k==keys.w then workers_screen()
      elseif k==keys.c then cannon_screen()
      elseif k==keys.q then return end
    end
  end
  local function tick_loop()
    while true do R.pairing_info(); U.sleep_ms(250) end
  end
  parallel.waitForAny(key_loop, tick_loop)
end

return M