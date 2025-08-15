-- /storm/modules/ui.lua
-- Military CMD UI: Home, Pairing, Approvals, Workers (live), Cannon (group control).
local C    = require("/storm/lib/config_loader")
local L    = require("/storm/lib/logger")
local Join = require("/storm/core/join_service")
local U    = require("/storm/lib/utils")

local M = {}
M.suspend_ticks = false

-- Colors (military CMD style)
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

local function setc(bg, fg)
  term.setBackgroundColor(bg or COL.bg)
  term.setTextColor(fg or COL.fg)
end

local function clip_str(s, width)
  if #s <= width then return s end
  -- show the tail with a leading ellipsis
  if width <= 3 then return string.sub(s, #s - width + 1) end
  return "…" .. string.sub(s, #s - (width - 2))
end

local function safe_write_line(y, text, fg)
  local w,_ = term.getSize()
  local cx, cy = term.getCursorPos()
  local oldBG, oldFG = term.getBackgroundColor(), term.getTextColor()
  term.setCursorPos(1, y)
  term.setBackgroundColor(COL.bg)
  term.setTextColor(fg or COL.fg)
  term.clearLine()
  if text then term.write(clip_str(text, w)) end
  term.setBackgroundColor(oldBG)
  term.setTextColor(oldFG)
  term.setCursorPos(cx, cy)
end

local function header()
  local line = (" SKYNET ETERNAL v4.0 | Cluster: %s | Dim: %s "):format(C.system.cluster_id or "?", C.system.dimension or "?")
  safe_write_line(1, line, COL.headerFG)
end

local function footer()
  local _, h = term.getSize()
  safe_write_line(h, "[P] Pair  [A] Approvals  [W] Workers  [C] Cannon  [Q] Quit", COL.footerFG)
end

local function pairing_info()
  if M.suspend_ticks then return end
  local code = Join.get_active_code()
  local port = Join.get_active_port()
  local _, h = term.getSize()
  if code and port then
    safe_write_line(h - 1, "Pairing ACTIVE :: Port: "..tostring(port).."  Code: "..tostring(code), COL.bannerFG)
  else
    safe_write_line(h - 1, "Pairing idle.", COL.bannerFG)
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

-- Render two-line prompt: instruction/status on status_y, live input on prompt_y
local function read_line_two_line(instruction, allowed)
  local w, h = term.getSize()
  local status_y = h - 3
  local prompt_y = h - 2

  safe_write_line(status_y, instruction, COL.statusFG)
  -- draw prompt arrow at left, then capture text within available width
  local function draw_buf(buf)
    term.setCursorPos(1, prompt_y)
    term.setBackgroundColor(COL.bg)
    term.setTextColor(COL.promptFG)
    term.clearLine()
    term.write("> ")
    term.setTextColor(COL.fg)
    local avail = w - 2 - 1 -- "> " is 2 chars, leave at least 1 char
    term.write(clip_str(buf, avail))
  end

  flush_chars(0.05)
  local buf = ""
  draw_buf(buf)
  while true do
    local got_char, ch
    local got_key, key
    parallel.waitForAny(
      function() local _, c = os.pullEvent("char"); got_char = true; ch = c end,
      function() local _, k = os.pullEvent("key");  got_key  = true; key = k end
    )
    if got_char then
      if (not allowed) or allowed(ch) then buf = buf .. ch; draw_buf(buf) end
    elseif got_key then
      if key == keys.enter then
        -- clear prompt line to avoid leftover
        term.setCursorPos(1, prompt_y); term.clearLine()
        return buf
      elseif key == keys.backspace then
        if #buf > 0 then buf = buf:sub(1, #buf - 1); draw_buf(buf) end
      elseif key == keys.escape then
        term.setCursorPos(1, prompt_y); term.clearLine()
        return nil
      end
    end
  end
end

local function redraw_home()
  term.clear()
  header()
  safe_write_line(3, "HOME", COL.bannerFG)
  safe_write_line(4, "Use: [P] Pair  [A] Approvals  [W] Workers  [C] Cannon  [Q] Quit")
  footer()
  pairing_info()
end

-- Pair wizard using two-line prompt
local function pair_wizard()
  M.suspend_ticks = true
  safe_write_line(3, "SECURE PAIRING SETUP", COL.bannerFG)
  local function allow_digits(c) return c >= '0' and c <= '9' end
  while true do
    local inp = read_line_two_line("Enter secure pairing port (0-65535) [Esc cancel]: ", allow_digits)
    if not inp or inp == "" then break end
    local port = tonumber(inp)
    if not port or port < 0 or port > 65535 then
      safe_write_line(3, "Invalid port. Try again.", COL.statusFG)
    else
      local ok, err = Join.start_pairing_on_port(port)
      if ok then break
      else
        if err == "noisy_port" then safe_write_line(3, "Port had traffic. Choose another.", COL.statusFG)
        else safe_write_line(3, "Pairing failed: "..tostring(err), COL.statusFG) end
      end
    end
  end
  M.suspend_ticks = false
  redraw_home()
end

local function approvals_screen()
  M.suspend_ticks = true
  term.clear(); header()
  safe_write_line(3, "APPROVALS", COL.bannerFG)
  local w, h = term.getSize()
  local list_top = 4
  local list_h   = h - 7
  while true do
    local list = Join.get_pending()
    for i = 1, list_h do
      term.setCursorPos(1, list_top + i); term.clearLine()
      local rec = list[i]
      if rec then
        term.write(clip_str(("[%d] id=%s  kind=%s  dev=%s  age=%ds"):format(
          i, rec.id, tostring(rec.hello.node_kind), tostring(rec.hello.device_id),
          math.floor((U.now_ms() - rec.ts) / 1000)), w))
      end
    end
    safe_write_line(h - 2, "Enter N approve | dN deny | q exit", COL.footerFG)
    local function allow(c) return (c>='0' and c<='9') or c=='d' or c=='D' or c=='q' or c=='Q' end
    local inp = read_line_two_line("", allow)
    if not inp or inp:lower()=="q" then break
    elseif inp:match("^%d+$") then
      local idx = tonumber(inp); local ok, err = Join.approve_index(idx)
      safe_write_line(h - 3, ok and ("Approved #"..idx) or ("Approve failed: "..tostring(err)), COL.statusFG)
    elseif inp:match("^[dD]%d+$") then
      local idx = tonumber(inp:sub(2)); local ok, err = Join.deny_index(idx)
      safe_write_line(h - 3, ok and ("Denied #"..idx) or ("Deny failed: "..tostring(err)), COL.statusFG)
    end
  end
  M.suspend_ticks = false
  redraw_home()
end

-- Workers screen: live refresh + input (char/key only)
local function workers_screen()
  M.suspend_ticks = true
  term.clear(); header()
  safe_write_line(3, "WORKERS", COL.bannerFG)
  local w, h = term.getSize()
  local list_top = 4
  local list_h   = h - 7
  local status_y = h - 3
  local prompt_y = h - 2
  local status_msg = ""

  local function draw_list()
    local lst = Join.get_workers()
    for i = 1, list_h do
      term.setCursorPos(1, list_top + i); term.clearLine()
      local it = lst[i]
      if it then
        local rtt = it.last_rtt and (tostring(it.last_rtt).."ms") or "n/a"
        local st  = (it.status and it.status.run~=nil) and (it.status.run and "RUN" or "STOP") or "?"
        term.write(clip_str(("[%d] dev=%s  modem=%s  rtt=%s  status=%s"):format(
          i, tostring(it.dev_id), tostring(it.modem or "?"), rtt, st), w))
      end
    end
  end

  local running = true
  local input_buf = ""
  local function prompt_draw()
    term.setCursorPos(1, prompt_y); term.clearLine()
    setc(COL.bg, COL.promptFG); term.write("> "); setc()
    local base = "pN ping | sN status | fN fire | lN log | q exit  "
    local avail = w - 2
    term.write(clip_str(base .. input_buf, avail))
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
            if it then
              local ok,err=Join.ping_worker(it.dev_id)
              status_msg = ok and ("Ping sent to dev="..tostring(it.dev_id)..". Waiting PONG...") or ("Ping failed: "..tostring(err))
            else status_msg="Invalid index." end
          elseif cmd:match("^[sS]%d+$") then
            local idx=tonumber(cmd:sub(2)); local it=lst[idx]
            if it then
              local ok,err=Join.status_worker(it.dev_id)
              status_msg = ok and ("Status requested from dev="..tostring(it.dev_id)..".") or ("Status failed: "..tostring(err))
            else status_msg="Invalid index." end
          elseif cmd:match("^[fF]%d+$") then
            local idx=tonumber(cmd:sub(2)); local it=lst[idx]
            if it then
              local ok,err=Join.fire_worker(it.dev_id,{ rounds=1 })
              status_msg = ok and ("Test fire sent to dev="..tostring(it.dev_id)..".") or ("Fire failed: "..tostring(err))
            else status_msg="Invalid index." end
          elseif cmd:match("^[lL]%d+$") then
            local idx=tonumber(cmd:sub(2)); local it=lst[idx]
            if it then
              safe_write_line(status_y, "Log text (Esc cancel):", COL.statusFG)
              local any=function(_) return true end
              local msg=read_line_two_line("", any)
              if msg then
                local ok,err=Join.log_worker(it.dev_id, msg)
                status_msg = ok and ("Log sent to dev="..tostring(it.dev_id)..".") or ("Log failed: "..tostring(err))
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
  M.suspend_ticks = false
  redraw_home()
end

-- Cannon screen with group selection and simple spread pattern
local function cannon_screen()
  M.suspend_ticks = true
  term.clear(); header()
  safe_write_line(3, "CANNON", COL.bannerFG)
  local w,h=term.getSize(); local top=4; local list_h=h-8; local status_y=h-4; local prompt_y=h-3
  local status_msg=""; local selected = {}

  local function draw_list()
    local lst=Join.get_workers()
    for i=1,list_h do
      term.setCursorPos(1, top+i); term.clearLine()
      local it=lst[i]
      if it then
        local selMark = selected[it.dev_id] and "*" or " "
        local yaw = it.status and tostring(it.status.yaw) or "?"
        local pitch = it.status and tostring(it.status.pitch) or "?"
        term.write(clip_str(("["..selMark.."] %d dev=%s  yaw=%s  pitch=%s"):format(i, tostring(it.dev_id), yaw, pitch), w))
      end
    end
  end

  local function prompt_draw(buf)
    term.setCursorPos(1, prompt_y); term.clearLine()
    setc(COL.bg, COL.promptFG); term.write("> "); setc()
    local base = "tN toggle | ls list | a yaw pitch | f rounds | spread d rounds | sN status | q"
    term.write(clip_str(base.."  "..buf, w-2))
  end

  local running=true; local input_buf=""
  local function refresh_loop()
    while running do
      draw_list()
      safe_write_line(status_y, status_msg, COL.statusFG)
      footer(); pairing_info()
      prompt_draw(input_buf)
      U.sleep_ms(400)
    end
  end

  local function toggle_by_index(idx)
    local lst=Join.get_workers(); local it=lst[idx]
    if it then
      if selected[it.dev_id] then selected[it.dev_id]=nil else selected[it.dev_id]=true end
      status_msg = "Selection: "..tostring(it.dev_id).." "..(selected[it.dev_id] and "added" or "removed")
    else
      status_msg = "Invalid index."
    end
  end

  local function apply_to_selected(fn)
    local any=false
    for dev,_ in pairs(selected) do any=true; fn(dev) end
    if not any then status_msg="No workers selected." end
  end

  local function input_loop()
    flush_chars(0.05)
    while running do
      local got_char, ch; local got_key, key
      parallel.waitForAny(
        function() local _, c=os.pullEvent("char"); got_char=true; ch=c end,
        function() local _, k=os.pullEvent("key");  got_key=true; key=k end
      )
      if got_char then input_buf=input_buf..ch; prompt_draw(input_buf)
      elseif got_key then
        if key==keys.backspace then if #input_buf>0 then input_buf=input_buf:sub(1,#input_buf-1); prompt_draw(input_buf) end
        elseif key==keys.enter then
          local cmd=input_buf; input_buf=""; prompt_draw(input_buf)
          if cmd=="" then
          elseif cmd:lower()=="q" then running=false; break
          elseif cmd:match("^[tT]%d+$") then
            toggle_by_index(tonumber(cmd:sub(2)))
          elseif cmd:lower()=="ls" then
            local buf="Selected: "; for dev,_ in pairs(selected) do buf=buf..tostring(dev).." " end; status_msg=buf
          elseif cmd:match("^[aA]%s+%-?%d+%.?%d*%s+%-?%d+%.?%d*$") then
            local y,p = cmd:match("^[aA]%s+([%-%.%d]+)%s+([%-%.%d]+)$")
            if y and p then
              apply_to_selected(function(dev)
                Join.aim_worker(dev, y, p)
              end)
              status_msg = "Aim sent to selected."
            else status_msg="Usage: a yaw pitch" end
          elseif cmd:match("^[fF]%s+%d+$") then
            local rounds = tonumber(cmd:match("%d+"))
            if rounds then
              apply_to_selected(function(dev) Join.fire_worker(dev, { rounds = rounds }) end)
              status_msg = "Fire sent to selected."
            else status_msg="Usage: f rounds" end
          elseif cmd:match("^[sS]%d+$") then
            local idx=tonumber(cmd:sub(2)); local lst=Join.get_workers(); local it=lst[idx]
            if it then Join.status_worker(it.dev_id); status_msg="Status requested."
            else status_msg="Invalid index." end
          elseif cmd:match("^[sS]pread%s+%-?%d+%.?%d*%s+%d+$") then
            local d,r = cmd:match("^[sS]pread%s+([%-%.%d]+)%s+(%d+)$")
            d = tonumber(d); r = tonumber(r)
            if not d or not r then status_msg="Usage: spread d rounds"
            else
              -- apply yaw offsets across selection deterministically
              local lst=Join.get_workers(); local selList={}
              for i=1,#lst do local it=lst[i]; if it and selected[it.dev_id] then selList[#selList+1]=it end end
              table.sort(selList, function(a,b) return tostring(a.dev_id) < tostring(b.dev_id) end)
              local n=#selList
              for i,it in ipairs(selList) do
                local offset = (i - (n+1)/2) * d
                -- request status to get current yaw? We just offset relative: command with aim: yaw_offset not supported yet
                -- We'll ask worker to aim absolute by adding offset to current known yaw if available
                local base_yaw = (it.status and it.status.yaw) or 0
                Join.aim_worker(it.dev_id, base_yaw + offset, (it.status and it.status.pitch) or 0)
                Join.fire_worker(it.dev_id, { rounds = r })
              end
              status_msg = "Spread fired across selected."
            end
          else
            status_msg="Unknown command. Use: tN | ls | a yaw pitch | f rounds | spread d rounds | sN | q"
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