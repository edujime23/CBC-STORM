-- /storm/modules/time_sync.lua
local M = {}

function M.now_ms()
  return os.epoch("utc")
end

function M.sync()
  -- stub for later median/RTT sync
  return true
end

return M