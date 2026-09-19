## The crypto this client needs, from OpenSSL.
##
## Bindings, not implementations. The first draft of this file was going to be
## SHA-512 and Ed25519 written out by hand and checked against RFC 8032's test
## vectors — which is the classic mistake: vectors prove you agree with the
## standard on the inputs someone thought to publish, and say nothing about
## the timing side channels and carry bugs that are the actual reason not to
## write your own. OpenSSL is already a hard requirement of this tree (the
## toolchain checks for it, `conn.nim` dlopens it for TLS), so using it here
## costs nothing that was not already being paid.
##
## Ed25519 through the EVP interface, which is the one OpenSSL 3 supports for
## it: `EVP_DigestSign` in its **one-shot** form, because Ed25519 is not a
## prehash scheme and the Update/Final pair is refused for it.

import std/sysrand
import frq/trace

const
  DLLUtilName = "libcrypto.so.3"
  EVP_PKEY_ED25519 = 1087.cint
    ## NID_ED25519, from OpenSSL's obj_mac.h. A number rather than a name
    ## because the header is not ours to include.

type
  EvpPkey = pointer
  EvpMdCtx = pointer
  EvpMd = pointer

{.push cdecl, dynlib: DLLUtilName, importc.}
proc EVP_sha256(): EvpMd
proc EVP_Digest(data: pointer, count: csize_t, md: pointer, size: ptr cuint,
                typ: EvpMd, engine: pointer): cint
proc EVP_PKEY_new_raw_private_key(typ: cint, e: pointer, key: pointer,
                                  keylen: csize_t): EvpPkey
proc EVP_PKEY_get_raw_public_key(pkey: EvpPkey, pub: pointer,
                                 len: ptr csize_t): cint
proc EVP_PKEY_free(pkey: EvpPkey)
proc EVP_MD_CTX_new(): EvpMdCtx
proc EVP_MD_CTX_free(ctx: EvpMdCtx)
proc EVP_DigestSignInit(ctx: EvpMdCtx, pctx: pointer, typ: EvpMd,
                        e: pointer, pkey: EvpPkey): cint
proc EVP_DigestSign(ctx: EvpMdCtx, sig: pointer, siglen: ptr csize_t,
                    tbs: pointer, tbslen: csize_t): cint
{.pop.}

type
  CryptoError* = object of CatchableError

  KeyPair* = object
    ## An Ed25519 key. The seed **is** the private key — which is why
    ## `frq.msgsig` chooses the seed rather than asking for one to be made.
    seed*: array[32, byte]
    public*: array[32, byte]

proc randomBytes*(n: int): seq[byte] =
  ## `n` bytes from the platform's own source of them.
  result = newSeq[byte](n)
  if n > 0 and not urandom(result):
    raise newException(CryptoError, "no randomness available")

proc sha256*(data: openArray[byte]): array[32, byte] =
  var size: cuint
  let ok = EVP_Digest(if data.len > 0: unsafeAddr data[0] else: nil,
                      data.len.csize_t, addr result[0], addr size,
                      EVP_sha256(), nil)
  if ok != 1 or size != 32:
    raise newException(CryptoError, "sha256 failed")

proc sha256*(s: string): array[32, byte] =
  sha256(s.toOpenArrayByte(0, s.high))

func toHex*(bs: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for b in bs:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 0x0F)]

proc keyFromSeed*(seed: openArray[byte]): KeyPair =
  ## The key a 32-byte seed names, with its public half.
  if seed.len != 32:
    raise newException(CryptoError, "an Ed25519 seed is 32 bytes")
  for i in 0 ..< 32: result.seed[i] = seed[i]

  let pkey = EVP_PKEY_new_raw_private_key(
    EVP_PKEY_ED25519, nil, unsafeAddr seed[0], 32)
  if pkey.isNil:
    raise newException(CryptoError, "OpenSSL would not take the seed")
  defer: EVP_PKEY_free(pkey)

  var n = 32.csize_t
  if EVP_PKEY_get_raw_public_key(pkey, addr result.public[0], addr n) != 1 or
     n != 32:
    raise newException(CryptoError, "could not derive the public key")

proc sign*(key: KeyPair, msg: openArray[byte]): array[64, byte] =
  ## Ed25519 over `msg`.
  ##
  ## One-shot `EVP_DigestSign`, not Update/Final: Ed25519 hashes the message
  ## internally as part of the scheme, so OpenSSL refuses the streaming form
  ## for it.
  let pkey = EVP_PKEY_new_raw_private_key(
    EVP_PKEY_ED25519, nil, unsafeAddr key.seed[0], 32)
  if pkey.isNil:
    raise newException(CryptoError, "OpenSSL would not take the key")
  defer: EVP_PKEY_free(pkey)

  let ctx = EVP_MD_CTX_new()
  if ctx.isNil:
    raise newException(CryptoError, "no digest context")
  defer: EVP_MD_CTX_free(ctx)

  if EVP_DigestSignInit(ctx, nil, nil, nil, pkey) != 1:
    raise newException(CryptoError, "could not start the signature")

  var n = 64.csize_t
  let ok = EVP_DigestSign(ctx, addr result[0], addr n,
                          if msg.len > 0: unsafeAddr msg[0] else: nil,
                          msg.len.csize_t)
  if ok != 1 or n != 64:
    raise newException(CryptoError, "could not sign")

proc sign*(key: KeyPair, s: string): array[64, byte] =
  sign(key, s.toOpenArrayByte(0, s.high))

proc newKey*(): KeyPair =
  ## A fresh key from the platform's randomness.
  let seed = randomBytes(32)
  trace("crypto", "minted an Ed25519 key")
  keyFromSeed(seed)
