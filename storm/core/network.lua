-- /storm/core/network.lua
local M = {
  sessions = {}
}

function M.init()
  -- Secure session router to be implemented (netsec)
end

function M.tick()
  -- Process inbound/outbound secure frames (next phase)
end

return M