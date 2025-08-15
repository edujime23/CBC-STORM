-- /storm/modules/ui.lua
-- Controller UI: secure pairing (ask port), approvals screen, cursor-safe drawing.
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
  safe_write_line(h, "[P] Pair  [A] Approvals  [Q] Quit")
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

-- Flush any pending 'char' events for a short window (does not consume modem_message).
local function flush_chars(ms)
  local duration = (ms or 0.05)
  local timer = os.startTimer(duration)
  while true do
    local fired = false
    local got_char = false
    parallel.waitForAny(
      function() local _, t = os.pullEvent("timer"); if t == timer then fired = true end end,
      function() local _ = os.pullEvent("char"); got_char = true end
    )
    if fired then break end
    -- if we saw a char, loop continues until timer fires
  end
end

-- Read a line using only 'char' + 'key' events (no other events are consumed).
-- allowed: function(c) -> bool, validates accepted chars (e.g., digits + 'd').
local function read_line_filtered(prompt, allowed)
  -- draw prompt
  local _, h = term.getSize()
  term.setCursorPos(1, h - 1); term.clearLine(); term.write(prompt)
  local buf = ""
  -- Remove any stale char events from the key used to enter the menu
  flush_chars(0.05)

  while true do
    local got_char, ch
    local got_key, key
    parallel.waitForAny(
      function() local _, c = os.pullEvent("char"); got_char = true; ch = c end,
      function() local _, k = os.pullEvent("key");  got_key  = true; key = k end
    )
    if got_char then
      if (not allowed) or allowed(ch) then
        buf = buf .. ch
        term.write(ch)
      end
    elseif got_key then
      if key == keys.enter then
        print("") -- move cursor
        return buf
      elseif key == keys.backspace then
        if #buf > 0 then
          local x, y = term.getCursorPos()
          term.setCursorPos(x-1, y)
          term.write(" ")
          term.setCursorPos(x-1, y)
          buf = string.sub(buf, 1, #buf - 1)
        end
      elseif key == keys.escape then
        print("")
        return nil
      end
    end
  end
end

local function approvals_screen()
  M.suspend_ticks = true
  term.clear(); header()
  local _, h = term.getSize()

  while true do
    term.setCursorPos(1, 3); term.clearLine(); term.write("Pending join requests:")
    local list = Join.get_pending()
    for i = 1, 10 do
      term.setCursorPos(1, 3 + i); term.clearLine()
      local rec = list[i]
      if rec then
        term.write(("[%d] id=%s  kind=%s  dev=%s  age=%ds"):format(
          i, rec.id, tostring(rec.hello.node_kind), tostring(rec.hello.device_id),
          math.floor((U.now_ms() - rec.ts) / 1000)
        ))
      end
    end

    safe_write_line(h - 2, "Enter number to approve, 'dN' to deny (e.g., d1), ENTER to refresh, ESC to exit.")

    -- Allowed characters: digits and 'd'/'D'
    local function allow_approvals_char(c)
      return (c >= '0' and c <= '9') or c == 'd' or c == 'D'
    end
    local inp = read_line_filtered("> ", allow_approvals_char)
    if not inp or inp == "" then
      -- refresh
    elseif inp:match("^%d+$") then
      local idx = tonumber(inp)
      local ok, err = Join.approve_index(idx)
      if not ok then
        L.warn("system", "Approve failed: "..tostring(err))
      end
    elseif inp:match("^[dD]%d+$") then
      local idx = tonumber(string.sub(inp, 2))
      local ok, err = Join.deny_index(idx)
      if not ok then
        L.warn("system", "Deny failed: "..tostring(err))
      end
    end
  end

  -- not reached; if you add a quit option, set M.suspend_ticks=false, redraw header/footer etc.
end

function M.run()
  term.clear(); header(); footer(); pairing_info()

  local function key_loop()
    while true do
      local _, k = os.pullEvent("key") -- only key events; never modem_message
      if k == keys.p then
        M.suspend_ticks = true
        term.setCursorPos(1, 3); term.clearLine(); print("SECURE PAIRING SETUP")
        -- We keep Join.start_pairing_interactive() for now (has its own prompts)
        Join.start_pairing_interactive()
        M.suspend_ticks = false
        header(); footer(); pairing_info()
      elseif k == keys.a then
        approvals_screen()
      elseif k == keys.q then
        return
      end
    end
  end

  local function tick_loop()
    while true do
      pairing_info()
      U.sleep_ms(150)
    end
  end

  parallel.waitForAny(key_loop, tick_loop)
end

return M