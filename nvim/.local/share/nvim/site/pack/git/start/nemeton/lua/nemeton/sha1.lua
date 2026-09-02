-- SHA-1, because GitLab identifies a line of a diff by one.
--
-- A multi-line comment's `line_range` names its two ends with a
-- `line_code`, which GitLab spells `<sha1 of the file's path>_<old
-- line>_<new line>`. Nothing else in this plugin hashes anything, and
-- nothing here is security: this is a lookup key GitLab happens to
-- build with a digest, and the alternative to forty lines of it is a
-- subprocess per comment for a string a hundred characters long.
--
-- Neovim has `sha256` and no `sha1`. LuaJIT's `bit` is what makes this
-- short: every value below is a 32-bit integer and every sum is taken
-- back to one with `tobit`.

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, tobit, tohex = bit.lshift, bit.rshift, bit.tobit, bit.tohex

local M = {}

local function rol(x, n)
  return bor(lshift(x, n), rshift(x, 32 - n))
end

--- The digest of `msg` as forty lowercase hex digits.
function M.hex(msg)
  local len = #msg
  -- The padding is the standard one: a 1 bit, zeroes up to 56 bytes of
  -- the last block, and the length in bits as a 64-bit big-endian
  -- number. The high half is written out for the sake of the shape
  -- rather than in hope: it is a file path being hashed, not a file.
  local bits = len * 8
  msg = msg
    .. "\128"
    .. string.rep("\0", (55 - len) % 64)
    .. string.char(
      0,
      0,
      0,
      0,
      band(rshift(bits, 24), 0xFF),
      band(rshift(bits, 16), 0xFF),
      band(rshift(bits, 8), 0xFF),
      band(bits, 0xFF)
    )

  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      a, b, c, d, e = tobit(rol(a, 5) + f + e + k + w[i]), a, rol(b, 30), c, d
    end
    h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
  end
  return tohex(h0) .. tohex(h1) .. tohex(h2) .. tohex(h3) .. tohex(h4)
end

return M
