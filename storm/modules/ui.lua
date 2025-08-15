-- /storm/modules/ui.lua
-- Controller UI: cursor-safe, hotkeys never leak into prompts, UI does all prompts.
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

-- Flush pending char events to avoid hotkey leaking into next prompt
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
      if (not allowed) or allowed(ch) then
        buf = buf .. ch
        term.write(ch)
      end
    elseif got_key then
      if key == keys.enter then
        print("")
        return buf
      elseif key == keys.backspace then
        if #buf > 0 then
          local x, y = term.getCursorPos()
          term.setCursorPos(x-1, y); term.write(" "); term.setCursorPos(x-1, y)
          buf = string.sub(buf, 1, #buf - 1)
        end
      elseif key == keys.escape then
        print("")
        return nil
      end
    end
  end
end

local function pair_wizard()
  M.suspend_ticks = true
  term.setCursorPos(1, 3); term.clearLine(); print("SECURE PAIRING SETUP")
  -- Port input: digits only
  local function allow_digits(c) return c >= '0' and c <= '9' end
  while true do
    local inp = read_line_filtered("Enter secure pairing port (0-65535): ", allow_digits)
    if not inp or inp == "" then break end
    local port = tonumber(inp)
    if not port or port < 0 or port > 65535 then
      term.setCursorPos(1, 3); term.clearLine(); print("Invalid port. Try again.")
    else
      local ok, err = Join.start_pairing_on_port(port)
      if ok then break end
      term.setCursorPos(1, 3); term.clearLine()
      if err == "noisy_port" then print("Port had traffic. Choose another.") else print("Pairing failed: "..tostring(err)) end
    end
  end
  M.suspend_ticks = false
  header(); footer(); pairing_info()
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
    local function allow_approvals_char(c) return (c >= '0' and c <= '9') or c=='d' or c=='D' end
    local inp = read_line_filtered("> ", allow_approvals_char)
    if not inp or inp == "" then
      -- refresh
    elseif inp:match("^%d+$") then
      local idx = tonumber(inp)
      local ok, err = Join.approve_index(idx)
      if not ok then L.warn("system", "Approve failed: "..tostring(err)) end
    elseif inp:match("^[dD]%d+$") then
      local idx = tonumber(string.sub(inp, 2))
      local ok, err = Join.deny_index(idx)
      if not ok then L.warn("system", "Deny failed: "..tostring(err)) end
    elseif inp == nil then
      break
    end
  end
  M.suspend_ticks = false
  term.clear(); header(); footer(); pairing_info()
end

function M.run()
  term.clear(); header(); footer(); pairing_info()
  local function key_loop()
    while true do
      local _, k = os.pullEvent("key") -- key-only, never modem_message
      if k == keys.p then
        pair_wizard()
      elseif k == keys.a then
        approvals_screen()
      elseif k == keys.q then
        return
      end
    end
  end
  local function tick_loop()
    while true do pairing_info(); U.sleep_ms(150) end
  end
  parallel.waitForAny(key_loop, tick_loop)
end

return M