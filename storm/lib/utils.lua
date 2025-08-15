-- /storm/lib/utils.lua
local M = {}

M.unpack = table.unpack or unpack

function M.sleep_ms(ms)
  if ms and ms > 0 then sleep(ms/1000) end
end

function M.clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi else return x end
end

function M.round(x, p)
  p = p or 1
  return math.floor(x/p + 0.5) * p
end

function M.read_json(path, default)
  if not fs.exists(path) then return default end
  local f = fs.open(path, "r")
  if not f then return default end
  local s = f.readAll()
  f.close()
  local ok, data = pcall(textutils.unserializeJSON, s)
  if ok and data then return data else return default end
end

function M.write_json(path, tbl)
  local s = textutils.serializeJSON(tbl)
  local f = fs.open(path, "w")
  f.write(s)
  f.close()
end

function M.now_ms()
  return os.epoch("utc")
end

return M