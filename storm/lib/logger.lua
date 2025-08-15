-- /storm/lib/logger.lua
local M = {}

local function openAppend(path)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  return fs.open(path, "a")
end

local function fmtTime()
  local t = os.time()
  return textutils.formatTime(t, true)
end

function M.log(name, level, msg)
  local f = openAppend("/storm/journal/" .. (name or "system") .. ".log")
  if not f then return end
  f.writeLine(("[%s][%s] %s"):format(fmtTime(), level or "INFO", msg))
  f.close()
end

function M.info(n, m) M.log(n, "INFO", m) end
function M.warn(n, m) M.log(n, "WARN", m) end
function M.error(n, m) M.log(n, "ERROR", m) end

return M