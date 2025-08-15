-- /storm/encryption/handshake.lua
-- Onboarding + simple lease issuance (skeleton). Uses placeholders until real crypto is plugged in.

local U = require("/storm/lib/utils")
local Crypto = require("/storm/encryption/crypto")

local M = {}

local function poor_hash(s)
  local h = 0
  for i = 1, #s do h = (h * 131 + string.byte(s, i)) % 0x7fffffff end
  return ("%08x"):format(h)
end

local function uuid()
  local b = Crypto.random(16)
  local t = {}
  for i = 1, #b do t[#t+1] = ("%02x"):format(string.byte(b, i)) end
  return table.concat(t)
end

-- Worker-side: build JOIN_HELLO
function M.build_join_hello(opts)
  -- opts: {node_kind, device_id, code, caps?}
  return {
    type = "JOIN_HELLO",
    node_kind = opts.node_kind or "worker",
    device_id = opts.device_id or os.getComputerID(),
    nonce = poor_hash(uuid() .. tostring(os.clock())),
    code = opts.code, -- plaintext for now; will become HMAC(code, transcript)
    caps = opts.caps or {},
    ts = U.now_ms()
  }
end

-- Master-side: verify JOIN_HELLO
function M.verify_join_hello(hello, active_code)
  if type(hello) ~= "table" or hello.type ~= "JOIN_HELLO" then
    return false, "bad_msg"
  end
  if not active_code or hello.code ~= active_code then
    return false, "bad_code"
  end
  return true
end

-- Master-side: create capability lease
function M.issue_lease(worker_info, ttl_ms, policy)
  local lease = {
    lease_id = uuid(),
    node_id = worker_info.device_id or 0,
    node_kind = worker_info.node_kind or "worker",
    issued_ms = U.now_ms(),
    expires_ms = U.now_ms() + (ttl_ms or (24*60*60*1000)),
    caps = policy and policy.caps or { can_fire = true, can_aim = true },
    policy = policy or { min_cooldown_ms = 3000 },
    sig = "master_sig_stub"
  }
  return lease
end

return M