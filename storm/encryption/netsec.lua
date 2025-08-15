-- /storm/encryption/netsec.lua
-- SecureChannel skeleton (pass-through). Will be wired to real AEAD + seq64 later.

local U = require("/storm/lib/utils")
local Crypto = require("/storm/encryption/crypto")

local M = {}

-- Session table example:
-- {
--   key_tx = "...",
--   key_rx = "...",
--   seq_tx = 0,
--   seq_rx = 0,
--   aead_nonce_salt = "salt",
--   rekey_at_ms = U.now_ms() + 10*60*1000
-- }

function M.new_session()
  return {
    key_tx = Crypto.random(32),
    key_rx = Crypto.random(32),
    seq_tx = 0,
    seq_rx = 0,
    aead_nonce_salt = Crypto.random(12),
    rekey_at_ms = U.now_ms() + 10*60*1000
  }
end

local function mk_nonce(salt, seq)
  -- placeholder nonce (12 bytes): salt (as-is) is used; in real impl combine salt+seq
  return salt
end

function M.wrap(session, aad, plaintext)
  session.seq_tx = (session.seq_tx + 1) % 0x100000000
  local nonce = mk_nonce(session.aead_nonce_salt, session.seq_tx)
  local ct, tag = Crypto.aead_encrypt(session.key_tx, nonce, aad, plaintext)
  return { seq = session.seq_tx, aad = aad, ct = ct, tag = tag }
end

function M.unwrap(session, frame)
  -- replay window and verify to be implemented; pass-through for now
  local nonce = mk_nonce(session.aead_nonce_salt, frame.seq)
  local pt, ok = Crypto.aead_decrypt(session.key_rx, nonce, frame.aad, frame.ct, frame.tag)
  if not ok then return nil, "bad_tag" end
  -- TODO: enforce seq_rx window
  session.seq_rx = frame.seq
  return pt
end

function M.needs_rekey(session)
  return U.now_ms() >= (session.rekey_at_ms or 0)
end

function M.rekey(session)
  session.key_tx = Crypto.random(32)
  session.key_rx = Crypto.random(32)
  session.aead_nonce_salt = Crypto.random(12)
  session.rekey_at_ms = U.now_ms() + 10*60*1000
end

return M