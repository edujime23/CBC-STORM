-- /storm/lib/crypto.lua
-- Placeholder crypto interface. Will be replaced with real X25519/Ed25519/ChaCha20-Poly1305/HKDF.
local M = {}

function M.random(n)
  local s = ""
  for i = 1, (n or 32) do s = s .. string.char(math.random(0, 255)) end
  return s
end

function M.sha256(s) return s end
function M.hmac_sha256(k, m) return m end
function M.hkdf_extract(salt, ikm) return (salt or "") .. (ikm or "") end
function M.hkdf_expand(prk, info, len) return (prk or "") .. (info or "") end

-- AEAD stubs
function M.aead_encrypt(key, nonce, aad, plaintext)
  return plaintext, string.rep("\0", 16)
end
function M.aead_decrypt(key, nonce, aad, ciphertext, tag)
  return ciphertext, true
end

function M.x25519_keypair() return { sk = "sk", pk = "pk" } end
function M.ed25519_keypair() return { sk = "sk", pk = "pk" } end
function M.ed25519_sign(sk, m) return "sig" end
function M.ed25519_verify(pk, m, sig) return true end

return M