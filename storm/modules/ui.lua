-- /storm/modules/ui.lua
-- Controller UI: cursor-safe, hotkeys never leak, UI handles prompts.
-- Adds Workers view with live refresh (ping/status/fire/log), and a persistent home screen.

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
  term.setBackgroundColor(oldBG)
  term.setTextColor(oldFG)
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
  local _, h = term.getSize()
  safe_write_line(3, "SECURE PAIRING SETUP")
  local function allow_digits(c) return c >= '0' and c <= '9' end
  while true do
    local inp = read_line_filtered("Enter secure pairing port (0-65535) [Esc cancel]: ", allow_digits)
    if not inp or inp == "" then break end
    local port = tonumber(inp)
    if not port or port < 0 or port > 65535 then
      safe_write_line(3, "Invalid port. Try again.")
    else
      local ok, err = Join.start_pairing_on_port(port)
      if ok then break
      else
        if err == "noisy_port" then safe_write_line(3, "Port had traffic. Choose another.")
        else safe_write_line(3, "Pairing failed: "..tostring(err)) end
      end
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
      elseif inp:lower() == "q" then
        break
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

-- Live Workers screen with parallel refresh and input
local function workers_screen()
  M.suspend_ticks = true
  term.clear(); header()
  local w, h = term.getSize()
  local top_y = 3
  local list_height = h - 6  -- leave bottom 3 lines for status/prompt/footer
  local status_y = h - 3
  local prompt_y = h - 2

  local status_msg = ""

  local function draw_list()
    term.setCursorPos(1, top_y); term.clearLine(); term.write("Workers:")
    local list = Join.get_workers()
    for i = 1, list_height do
      term.setCursorPos(1, top_y + i)
      term.clearLine()
      local item = list[i]
      if item then
        local rtt = item.last_rtt and (tostring(item.last_rtt).."ms") or "n/a"
        local st  = (item.status and item.status.run ~= nil) and (item.status.run and "RUN" or "STOP") or "?"
        term.write(("[%d] dev=%s  modem=%s  rtt=%s  status=%s"):format(
          i, tostring(item.dev_id), tostring(item.modem or "?"), rtt, st))
      end
    end
    return list
  end

  local running = true
  local input_buf = ""

  local function refresh_loop()
    while running do
      local list = draw_list()
      safe_write_line(status_y, status_msg)
      -- redraw footer and pairing line ourselves (suspend_ticks true)
      safe_write_line(h, "[P] Pair  [A] Approvals  [W] Workers  [Q] Quit")
      safe_write_line(h - 1, "") -- keep bottom status for pairing free
      -- redraw prompt with buffer
      term.setCursorPos(1, prompt_y); term.clearLine()
      term.write("Type: pN ping | sN status | fN test fire | lN log | q exit.  > " .. input_buf)
      U.sleep_ms(400)
    end
  end

  local function input_loop()
    flush_chars(0.05)
    while running do
      local ev, p = os.pullEvent()
      if ev == "char" then
        input_buf = input_buf .. p
        term.setCursorPos(1, prompt_y); term.clearLine()
        term.write("Type: pN ping | sN status | fN test fire | lN log | q exit.  > " .. input_buf)
      elseif ev == "key" then
        if p == keys.backspace then
          if #input_buf > 0 then
            input_buf = input_buf:sub(1, #input_buf - 1)
            term.setCursorPos(1, prompt_y); term.clearLine()
            term.write("Type: pN ping | sN status | fN test fire | lN log | q exit.  > " .. input_buf)
          end
        elseif p == keys.enter then
          local cmd = input_buf
          input_buf = ""
          term.setCursorPos(1, prompt_y); term.clearLine()
          term.write("Type: pN ping | sN status | fN test fire | lN log | q exit.  > ")

          -- Process command
          local list = Join.get_workers()
          if cmd == "" then
            -- no-op; refresh happens automatically
          elseif cmd:lower() == "q" then
            running = false
            break
          elseif cmd:match("^[pP]%d+$") then
            local idx = tonumber(cmd:sub(2)); local w = list[idx]
            if w then
              local ok, err = Join.ping_worker(w.dev_id)
              status_msg = ok and ("Ping sent to dev="..tostring(w.dev_id)..". Waiting for PONG...") or ("Ping failed: "..tostring(err))
            else
              status_msg = "Invalid index."
            end
          elseif cmd:match("^[sS]%d+$") then
            local idx = tonumber(cmd:sub(2)); local w = list[idx]
            if w then
              local ok, err = Join.status_worker(w.dev_id)
              status_msg = ok and ("Status requested from dev="..tostring(w.dev_id)..".") or ("Status failed: "..tostring(err))
            else
              status_msg = "Invalid index."
            end
          elseif cmd:match("^[fF]%d+$") then
            local idx = tonumber(cmd:sub(2)); local w = list[idx]
            if w then
              local ok, err = Join.fire_worker(w.dev_id, { rounds=1 })
              status_msg = ok and ("Test fire sent to dev="..tostring(w.dev_id)..".") or ("Fire failed: "..tostring(err))
            else
              status_msg = "Invalid index."
            end
          elseif cmd:match("^[lL]%d+$") then
            local idx = tonumber(cmd:sub(2)); local w = list[idx]
            if w then
              -- small inline message read
              safe_write_line(prompt_y, "Log text (Enter to send, Esc to cancel): ")
              local any = function(_) return true end
              local msg = read_line_filtered("", any)
              if msg then
                local ok, err = Join.log_worker(w.dev_id, msg)
                status_msg = ok and ("Log sent to dev="..tostring(w.dev_id)..".") or ("Log failed: "..tostring(err))
              else
                status_msg = "Log cancelled."
              end
            else
              status_msg = "Invalid index."
            end
          else
            status_msg = "Unknown command. Use pN/sN/fN/lN/q."
          end
        elseif p == keys.escape then
          running = false
          break
        end
      end
      -- Never consume modem_message here
    end
  end

  parallel.waitForAny(refresh_loop, input_loop)
  M.suspend_ticks = false
  redraw_all()
end

function M.run()
  redraw_all()
  local function key_loop()
    while true do
      local _, k = os.pullEvent("key")
      if k == keys.p then
        pair_wizard()
      elseif k == keys.a then
        approvals_screen()
      elseif k == keys.w then
        workers_screen()
      elseif k == keys.q then
        return
      end
    end
  end
  local function tick_loop()
    while true do pairing_info(); U.sleep_ms(250) end
  end
  parallel.waitForAny(key_loop, tick_loop)
end

return M