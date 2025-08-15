-- /storm/lib/hopper.lua
local U = require("/storm/lib/utils")

local M = { blacklist = {} }

local function clampChan(ch)
  return 10000 + (ch % 50000)
end

-- NOTE: Placeholder hash; will be replaced by HMAC-SHA256(secret, role|epoch|salt)
local function poor_hash(raw)
  local h = 0
  for i = 1, #raw do
    h = (h * 131 + string.byte(raw, i)) % 0x7fffffff
  end
  return h
end

function M.schedule(secret, role, epoch_idx, salt)
  local raw = tostring(secret) .. ":" .. tostring(role) .. ":" .. tostring(epoch_idx) .. ":" .. tostring(salt or "")
  local h = poor_hash(raw)
  local ch = clampChan(h)
  local tries = 0
  while M.blacklist[ch] and M.blacklist[ch] > U.now_ms() and tries < 64 do
    ch = clampChan(ch + 7919)
    tries = tries + 1
  end
  return ch
end

function M.fast_skip(current)
  M.blacklist[current] = U.now_ms() + 600000 -- 10m
end

function M.blacklist_add(ch, ttl_ms)
  M.blacklist[ch] = U.now_ms() + (ttl_ms or 600000)
end

return M