-- /storm/encryption/handshake.lua
local U = require("/storm/lib/utils")
local Crypto = require("/storm/encryption/crypto")

local DEBUG = true
local HS = {}

local function code_bytes(code, dev_id)
  return Crypto.sha256(tostring(code) .. ":" .. tostring(dev_id))
end

function HS.build_join_hello(opts)
  local dev_id = opts.device_id or os.getComputerID()
  local node_kind = opts.node_kind or "worker"
  local nonceW = Crypto.random(16)
  local key = code_bytes(opts.code, dev_id)
  local mac = Crypto.hmac_sha256(key, tostring(dev_id) .. "|" .. nonceW)
  local hello = {
    type = "JOIN_HELLO",
    node_kind = node_kind,
    device_id = dev_id,
    nonceW = nonceW,
    mac = mac,
    caps = opts.caps or {},
    ts = U.now_ms()
  }
  if DEBUG then
    print(("[Handshake] HELLO dev=%s kind=%s ts=%s"):format(tostring(dev_id), tostring(node_kind), tostring(hello.ts)))
  end
  return hello
end

function HS.verify_join_hello(hello, active_code)
  if type(hello) ~= "table" or hello.type ~= "JOIN_HELLO" then
    if DEBUG then print("[Handshake] verify_hello: bad_msg") end
    return false, "bad_msg"
  end
  if not active_code then return false, "no_code" end
  local key = code_bytes(active_code, hello.device_id)
  local expect = Crypto.hmac_sha256(key, tostring(hello.device_id) .. "|" .. (hello.nonceW or ""))
  local ok = (expect == hello.mac)
  if DEBUG then
    print(("[Handshake] verify_hello dev=%s ok=%s"):format(tostring(hello.device_id), tostring(ok)))
  end
  if not ok then return false, "bad_code" end
  return true
end

function HS.build_welcome_seed(dev_id, code, nonceW)
  local nonceM = Crypto.random(16)
  local key = code_bytes(code, dev_id)
  local mac = Crypto.hmac_sha256(key, tostring(dev_id) .. "|" .. nonceW .. "|" .. nonceM)
  return {
    type="WELCOME_SEED",
    device_id = dev_id,
    nonceM = nonceM,
    mac = mac,
    ts = U.now_ms()
  }
end

function HS.verify_welcome_seed(seed, code, nonceW)
  if type(seed)~="table" or seed.type~="WELCOME_SEED" then return false, "bad_msg" end
  local key = code_bytes(code, seed.device_id)
  local expect = Crypto.hmac_sha256(key, tostring(seed.device_id) .. "|" .. nonceW .. "|" .. seed.nonceM)
  if expect ~= seed.mac then return false, "bad_mac" end
  return true
end

function HS.derive_pair_session(code, dev_id, nonceW, nonceM, NetSec)
  local key = code_bytes(code, dev_id)
  return NetSec.derive_session(key, nonceW, nonceM)
end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = deepcopy(x) end
  return t
end

function HS.issue_lease(worker_info, ttl_ms, policy)
  -- Avoid repeated table references: deep copy both policy and caps
  local pol = {}
  local caps = { can_fire = true, can_aim = true }
  if type(policy) == "table" then
    -- copy policy without caps
    for k, v in pairs(policy) do
      if k ~= "caps" then pol[k] = deepcopy(v) end
    end
    if type(policy.caps) == "table" then
      caps = deepcopy(policy.caps)
    end
  end

  local lease = {
    lease_id  = Crypto.hex(Crypto.random(8)),
    node_id   = worker_info.device_id or 0,
    node_kind = worker_info.node_kind or "worker",
    issued_ms = U.now_ms(),
    expires_ms= U.now_ms() + (ttl_ms or (24*60*60*1000)),
    caps      = caps,      -- separate table
    policy    = pol,       -- separate table (no nested caps)
    sig       = "master_sig_stub"
  }
  if DEBUG then
    print(("[Handshake] issue_lease id=%s node=%s expires=%s")
      :format(lease.lease_id, tostring(lease.node_id), tostring(lease.expires_ms)))
  end
  return lease
end

return HS