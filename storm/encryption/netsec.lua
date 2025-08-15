-- /storm/encryption/netsec.lua
-- Encrypted frames (ETM): ChaCha20-CTR + HMAC-SHA256(tag).
-- Session from HKDF(code, nonceW||nonceM).
local U = require("/storm/lib/utils")
local C = require("/storm/encryption/crypto")

local NetSec = {}

local function trunc16(s) return string.sub(s, 1, 16) end

local function be8(n)
  local t={}
  for i=7,0,-1 do t[#t+1]=string.char(bit32.band(bit32.rshift(n, i*8),255)) end
  return table.concat(t)
end

local function build_nonce(salt4, seq64)
  return salt4 .. be8(seq64)
end

function NetSec.derive_session(key_ikm, nonceW, nonceM)
  local prk = C.hkdf_extract(nonceW..nonceM, key_ikm)
  local okm = C.hkdf_expand(prk, "CBC-STORM/PAIR", 64)
  local k_master = string.sub(okm,1,32)
  local nonce_salt4 = string.sub(okm,33,36)
  local k_enc = C.hmac_sha256(k_master, "enc")
  local k_mac = C.hmac_sha256(k_master, "mac")
  return { k_enc=k_enc, k_mac=k_mac, salt4=nonce_salt4, seq_tx=0, seq_rx=-1 }
end

local function aead_encrypt(sess, aad, plaintext)
  sess.seq_tx = (sess.seq_tx + 1) % 0x10000000000000000
  local nonce = build_nonce(sess.salt4, sess.seq_tx)
  local ct = C.chacha20_xor(sess.k_enc, nonce, 1, plaintext)
  local mac = C.hmac_sha256(sess.k_mac, (aad or "") .. nonce .. ct)
  return sess.seq_tx, nonce, ct, trunc16(mac)
end

local function aead_decrypt(sess, aad, seq, nonce, ct, tag)
  if seq <= (sess.seq_rx or -1) then return nil, "replay" end
  local mac = C.hmac_sha256(sess.k_mac, (aad or "") .. nonce .. ct)
  if trunc16(mac) ~= tag then return nil, "bad_tag" end
  local pt = C.chacha20_xor(sess.k_enc, nonce, 1, ct)
  sess.seq_rx = seq
  return pt
end

function NetSec.wrap(sess, inner_tbl, aad_tbl)
  local aad = aad_tbl and textutils.serialize(aad_tbl) or ""
  local pt  = textutils.serialize(inner_tbl)
  local seq, nonce, ct, tag = aead_encrypt(sess, aad, pt)
  return { type="ENC", seq=seq, nonce=nonce, ct=ct, tag=tag }
end

function NetSec.unwrap(sess, frame, aad_tbl)
  if type(frame)~="table" or frame.type~="ENC" then return nil, "not_enc" end
  local aad = aad_tbl and textutils.serialize(aad_tbl) or ""
  local pt, err = aead_decrypt(sess, aad, frame.seq, frame.nonce, frame.ct, frame.tag)
  if not pt then return nil, err end
  local ok, tbl = pcall(textutils.unserialize, pt)
  if not ok or type(tbl)~="table" then return nil, "bad_inner" end
  return tbl
end

return NetSec