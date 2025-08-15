-- /storm/encryption/crypto.lua
-- Pure-Lua crypto primitives for CBC-STORM:
--  - SHA-256
--  - HMAC-SHA256
--  - HKDF-SHA256
--  - ChaCha20 stream (RFC 7539 core, 96-bit nonce, CTR)
-- Encrypt-then-MAC is implemented in netsec.lua (ChaCha20-CTR + HMAC-SHA256)

local bit32 = bit32
local band, bor, bxor = bit32.band, bit32.bor, bit32.bxor
local rshift, lshift = bit32.rshift, bit32.lshift
local rol = bit32.lrotate

local Crypto = {}

-- Random (simple). Seed outside (e.g., with os.epoch and keypress jitter) before pairing.
function Crypto.random(n)
  local s = ""
  for i = 1, (n or 32) do s = s .. string.char(math.random(0, 255)) end
  return s
end

local function tobytes_le32(x)
  return string.char(
    band(x,255),
    band(rshift(x,8),255),
    band(rshift(x,16),255),
    band(rshift(x,24),255)
  )
end

local function frombytes_le32(s, i)
  local b1 = string.byte(s,i) or 0
  local b2 = string.byte(s,i+1) or 0
  local b3 = string.byte(s,i+2) or 0
  local b4 = string.byte(s,i+3) or 0
  return bor(b1, lshift(b2,8), lshift(b3,16), lshift(b4,24))
end

function Crypto.hex(s)
  local t = {}
  for i=1,#s do t[#t+1] = string.format("%02x", s:byte(i)) end
  return table.concat(t)
end

-- SHA-256
do
  local H0 = {
    0x6A09E667,0xBB67AE85,0x3C6EF372,0xA54FF53A,
    0x510E527F,0x9B05688C,0x1F83D9AB,0x5BE0CD19
  }
  local K = {
    0x428A2F98,0x71374491,0xB5C0FBCF,0xE9B5DBA5,0x3956C25B,0x59F111F1,0x923F82A4,0xAB1C5ED5,
    0xD807AA98,0x12835B01,0x243185BE,0x550C7DC3,0x72BE5D74,0x80DEB1FE,0x9BDC06A7,0xC19BF174,
    0xE49B69C1,0xEFBE4786,0x0FC19DC6,0x240CA1CC,0x2DE92C6F,0x4A7484AA,0x5CB0A9DC,0x76F988DA,
    0x983E5152,0xA831C66D,0xB00327C8,0xBF597FC7,0xC6E00BF3,0xD5A79147,0x06CA6351,0x14292967,
    0x27B70A85,0x2E1B2138,0x4D2C6DFC,0x53380D13,0x650A7354,0x766A0ABB,0x81C2C92E,0x92722C85,
    0xA2BFE8A1,0xA81A664B,0xC24B8B70,0xC76C51A3,0xD192E819,0xD6990624,0xF40E3585,0x106AA070,
    0x19A4C116,0x1E376C08,0x2748774C,0x34B0BCB5,0x391C0CB3,0x4ED8AA4A,0x5B9CCA4F,0x682E6FF3,
    0x748F82EE,0x78A5636F,0x84C87814,0x8CC70208,0x90BEFFFA,0xA4506CEB,0xBEF9A3F7,0xC67178F2
  }

  local function Sigma0(x) return bxor(rol(x,30), rol(x,19), rol(x,10)) end
  local function Sigma1(x) return bxor(rol(x,26), rol(x,21), rol(x,7)) end
  local function sigma0(x) return bxor(rol(x,25), rol(x,14), rshift(x,3)) end
  local function sigma1(x) return bxor(rol(x,15), rol(x,13), rshift(x,10)) end
  local function Ch(x,y,z) return bxor(bit32.band(x,y), bit32.band(bit32.bxor(x,0xffffffff), z)) end
  local function Maj(x,y,z) return bxor(bit32.band(x,y), bit32.band(x,z), bit32.band(y,z)) end

  local function preprocess(msg)
    local ml = #msg * 8
    msg = msg..string.char(0x80)
    local pad = (56 - (#msg % 64)) % 64
    msg = msg .. string.rep("\0", pad)
    local hi32 = math.floor(ml / 2^32)
    local lo32 = ml % 2^32
    return msg .. string.char(
      band(rshift(hi32,24),255), band(rshift(hi32,16),255), band(rshift(hi32,8),255), band(hi32,255),
      band(rshift(lo32,24),255), band(rshift(lo32,16),255), band(rshift(lo32,8),255), band(lo32,255)
    )
  end

  function Crypto.sha256(msg)
    local H = {table.unpack(H0)}
    msg = preprocess(msg)
    for i=1,#msg,64 do
      local w = {}
      for j=0,15 do
        local a = string.byte(msg, i+j*4+1) or 0
        local b = string.byte(msg, i+j*4+2) or 0
        local c = string.byte(msg, i+j*4+3) or 0
        local d = string.byte(msg, i+j*4+4) or 0
        w[j+1] = bor(lshift(a,24), lshift(b,16), lshift(c,8), d)
      end
      for j=17,64 do
        w[j] = (w[j-16] + sigma0(w[j-15]) + w[j-7] + sigma1(w[j-2])) % 2^32
      end
      local a,b,c,d,e,f,g,h = H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8]
      for j=1,64 do
        local T1 = (h + Sigma1(e) + Ch(e,f,g) + K[j] + w[j]) % 2^32
        local T2 = (Sigma0(a) + Maj(a,b,c)) % 2^32
        h,g,f,e,d,c,b,a = g,f,e,(d+T1)%2^32,c,b,a,(T1+T2)%2^32
      end
      H[1]=(H[1]+a)%2^32; H[2]=(H[2]+b)%2^32; H[3]=(H[3]+c)%2^32; H[4]=(H[4]+d)%2^32
      H[5]=(H[5]+e)%2^32; H[6]=(H[6]+f)%2^32; H[7]=(H[7]+g)%2^32; H[8]=(H[8]+h)%2^32
    end
    local out = {}
    for i=1,8 do
      out[#out+1]=string.char(
        band(rshift(H[i],24),255), band(rshift(H[i],16),255), band(rshift(H[i],8),255), band(H[i],255)
      )
    end
    return table.concat(out)
  end
end

function Crypto.hmac_sha256(key, msg)
  local block = 64
  if #key > block then key = Crypto.sha256(key) end
  key = key .. string.rep("\0", block - #key)
  local o = key:gsub(".", function(c) return string.char(bxor(string.byte(c), 0x5c)) end)
  local i = key:gsub(".", function(c) return string.char(bxor(string.byte(c), 0x36)) end)
  return Crypto.sha256(o .. Crypto.sha256(i .. msg))
end

function Crypto.hkdf_extract(salt, ikm)
  salt = salt or string.rep("\0", 32)
  return Crypto.hmac_sha256(salt, ikm)
end

function Crypto.hkdf_expand(prk, info, len)
  local t, ok = "", ""
  local out = {}
  local block = 0
  while #t < len do
    block = block + 1
    ok = Crypto.hmac_sha256(prk, ok .. info .. string.char(block))
    out[#out+1] = ok
    t = table.concat(out)
  end
  return string.sub(t, 1, len)
end

-- ChaCha20 stream (RFC 7539 core)
local SIGMA = { 0x61707865,0x3320646e,0x79622d32,0x6b206574 }
local function quarter(a,b,c,d)
  a=(a+b)%2^32; d=bxor(d,a); d=rol(d,16)
  c=(c+d)%2^32; b=bxor(b,c); b=rol(b,12)
  a=(a+b)%2^32; d=bxor(d,a); d=rol(d,8)
  c=(c+d)%2^32; b=bxor(b,c); b=rol(b,7)
  return a,b,c,d
end
local function chacha20_block(key, counter, nonce)
  local k = {}
  for i=1,8 do k[i]=frombytes_le32(key,(i-1)*4+1) end
  local n1 = counter
  local n2 = frombytes_le32(nonce,1)
  local n3 = frombytes_le32(nonce,5)
  local n4 = frombytes_le32(nonce,9)
  local state = {
    SIGMA[1],SIGMA[2],SIGMA[3],SIGMA[4],
    k[1],k[2],k[3],k[4],k[5],k[6],k[7],k[8],
    n1,n2,n3,n4
  }
  local w = {table.unpack(state)}
  for _=1,10 do
    w[1],w[5],w[9],w[13] = quarter(w[1],w[5],w[9],w[13])
    w[2],w[6],w[10],w[14]= quarter(w[2],w[6],w[10],w[14])
    w[3],w[7],w[11],w[15]= quarter(w[3],w[7],w[11],w[15])
    w[4],w[8],w[12],w[16]= quarter(w[4],w[8],w[12],w[16])
    w[1],w[6],w[11],w[16]= quarter(w[1],w[6],w[11],w[16])
    w[2],w[7],w[12],w[13]= quarter(w[2],w[7],w[12],w[13])
    w[3],w[8],w[9],w[14]= quarter(w[3],w[8],w[9],w[14])
    w[4],w[5],w[10],w[15]= quarter(w[4],w[5],w[10],w[15])
  end
  local out={}
  for i=1,16 do
    local v=(w[i]+state[i])%2^32
    out[#out+1]=tobytes_le32(v)
  end
  return table.concat(out)
end

function Crypto.chacha20_xor(key, nonce, counter, plaintext)
  local out = {}
  local off = 1
  local ctr = counter or 1
  while off <= #plaintext do
    local ks = chacha20_block(key, ctr, nonce)
    ctr = (ctr + 1) % 2^32
    local blen = math.min(64, #plaintext - off + 1)
    local block = string.sub(ks, 1, blen)
    local t={}
    for i=1,blen do
      t[i] = string.char(bxor(plaintext:byte(off+i-1), block:byte(i)))
    end
    out[#out+1] = table.concat(t)
    off = off + blen
  end
  return table.concat(out)
end

return Crypto