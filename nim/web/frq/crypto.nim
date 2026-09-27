## Signing, in a browser.
##
## The desktop binds OpenSSL's EVP interface for Ed25519 and SHA-256. A
## browser has neither that library nor a synchronous way to do the same
## work: WebCrypto signs through a Promise, and everything that wants a
## signature here wants it inline, on the line being sent.
##
## Ed25519 comes from TweetNaCl (`flutter/web/nacl-fast.min.js`, loaded by
## `index.html` before this core), which signs synchronously. It is the same
## sort of answer as binding OpenSSL: somebody else's audited implementation,
## not ours. It is a single self-contained script, so it needs no bundling
## step — which is what kept `@noble/ed25519` out.
##
## Without it this build signed nothing, and a signed-in reader was refused
## every edit, delete and reaction with `SIGNATURE_REQUIRED`.
##
## SHA-256 is written out below instead: TweetNaCl carries SHA-512 only, and
## SHA-256 is short, fixed, and checked against the published vectors in
## `web/test/smoke.js`.
##
## If the script is missing, `newKey` still returns a pair with no public
## half, `msgsig` sees that and does not claim to be signing, and the reader
## is where a guest is — which is where this build used to leave everyone.

type
  KeyPair* = object
    public*: seq[byte]
    private*: seq[byte]
      ## TweetNaCl's 64-byte secret key: the seed, then the public half.

  CryptoError* = object of CatchableError

proc randomBytes*(n: int): seq[byte] =
  ## From the platform's CSPRNG, through `getRandomValues`.
  result = newSeq[byte](n)
  {.emit: """
  var buf = new Uint8Array(`n`);
  (globalThis.crypto || window.crypto).getRandomValues(buf);
  for (var i = 0; i < `n`; i++) { `result`[i] = buf[i]; }
  """.}

# ------------------------------------------------------------------ SHA-256

const k256: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

func rotr(x: uint32, n: int): uint32 {.inline.} =
  (x shr n) or (x shl (32 - n))

proc sha256*(data: openArray[byte]): array[32, byte] =
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
           0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  # The message, a 1 bit, zeros to 56 mod 64, and the length in bits.
  var msg = newSeq[byte](data.len)
  for i, b in data: msg[i] = b
  msg.add 0x80'u8
  while msg.len mod 64 != 56: msg.add 0'u8
  # A length in bits over 2^32 would be a 512 MB line; the high word is zero.
  let bits = data.len * 8
  for i in 0 ..< 4: msg.add 0'u8
  for i in countdown(3, 0): msg.add byte((bits shr (8 * i)) and 0xff)

  var w: array[64, uint32]
  var chunk = 0
  while chunk < msg.len:
    for i in 0 ..< 16:
      let o = chunk + 4 * i
      w[i] = (uint32(msg[o]) shl 24) or (uint32(msg[o + 1]) shl 16) or
             (uint32(msg[o + 2]) shl 8) or uint32(msg[o + 3])
    for i in 16 ..< 64:
      let s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor (w[i - 15] shr 3)
      let s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var a = h[0]
    var b = h[1]
    var c = h[2]
    var d = h[3]
    var e = h[4]
    var f = h[5]
    var g = h[6]
    var hh = h[7]
    for i in 0 ..< 64:
      let S1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + S1 + ch + k256[i] + w[i]
      let S0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = S0 + maj
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b
      b = a
      a = t1 + t2
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    h[5] += f
    h[6] += g
    h[7] += hh
    chunk += 64

  for i in 0 ..< 8:
    for j in 0 ..< 4:
      result[4 * i + j] = byte((h[i] shr (24 - 8 * j)) and 0xff)

proc bytesOf(s: string): seq[byte] =
  ## A Nim string is already its UTF-8 bytes on this backend too; this only
  ## changes what the type says they are.
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc sha256*(s: string): array[32, byte] =
  sha256(bytesOf(s))

func toHex*(bs: openArray[byte]): string =
  const hex = "0123456789abcdef"
  for b in bs:
    result.add hex[int(b shr 4)]
    result.add hex[int(b and 0x0f)]

# ------------------------------------------------------------------ Ed25519

proc naclReady(): bool =
  {.emit: """
  `result` = typeof globalThis.nacl === 'object' && globalThis.nacl !== null &&
             typeof globalThis.nacl.sign === 'function' &&
             typeof globalThis.nacl.sign.detached === 'function';
  """.}

proc keyFromSeed*(seed: openArray[byte]): KeyPair =
  if not naclReady() or seed.len != 32: return KeyPair()
  var pub, priv: seq[byte]
  {.emit: """
  var kp = globalThis.nacl.sign.keyPair.fromSeed(Uint8Array.from(`seed`));
  `pub` = Array.from(kp.publicKey);
  `priv` = Array.from(kp.secretKey);
  """.}
  KeyPair(public: pub, private: priv)

proc newKey*(): KeyPair =
  ## A fresh key from a fresh seed — or, with no TweetNaCl on the page, a
  ## pair with no public half, which is how `msgsig` knows there is nothing
  ## to sign with. Deliberately not an exception: being unable to sign is a
  ## thing this client can carry on without, and a sign-in that threw here
  ## would take the whole connection with it.
  keyFromSeed(randomBytes(32))

proc sign*(key: KeyPair, msg: openArray[byte]): array[64, byte] =
  if not naclReady() or key.private.len != 64:
    raise newException(CryptoError, "no signing key in this build")
  var sig: seq[byte]
  let priv = key.private
  {.emit: """
  `sig` = Array.from(globalThis.nacl.sign.detached(Uint8Array.from(`msg`),
                                                  Uint8Array.from(`priv`)));
  """.}
  for i in 0 ..< 64: result[i] = sig[i]

proc sign*(key: KeyPair, s: string): array[64, byte] =
  sign(key, bytesOf(s))
