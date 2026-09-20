## Signing, in a browser — or rather, not yet.
##
## The desktop binds OpenSSL's EVP interface for Ed25519 and SHA-256. A
## browser has neither that library nor a synchronous way to do the same
## work: WebCrypto signs through a Promise, and everything that wants a
## signature here wants it inline, on the line being sent.
##
## So this says so, rather than pretending. `newKey` returns a pair with no
## public half, `msgsig` sees that and does not claim to be signing, and the
## reader is in the position a guest is in: their lines are relayed by the
## server with the server's word for who sent them, and freeq refuses the
## reactions and edits that need an author's signature.
##
## The way out is a synchronous Ed25519 in JavaScript — `@noble/ed25519` has
## one, and is the same sort of answer as binding OpenSSL: somebody else's
## audited implementation, not ours. That needs a bundling step this build
## does not have yet, which is why it is written down here instead of done.

import std/times

type
  KeyPair* = object
    public*: seq[byte]
    private*: seq[byte]

  CryptoError* = object of CatchableError

proc randomBytes*(n: int): seq[byte] =
  ## From the platform's CSPRNG, through `getRandomValues`.
  result = newSeq[byte](n)
  {.emit: """
  var buf = new Uint8Array(`n`);
  (globalThis.crypto || window.crypto).getRandomValues(buf);
  for (var i = 0; i < `n`; i++) { `result`[i] = buf[i]; }
  """.}

proc sha256*(data: openArray[byte]): array[32, byte] =
  raise newException(CryptoError, "SHA-256 is not available in this build")

proc sha256*(s: string): array[32, byte] =
  raise newException(CryptoError, "SHA-256 is not available in this build")

func toHex*(bs: openArray[byte]): string =
  const hex = "0123456789abcdef"
  for b in bs:
    result.add hex[int(b shr 4)]
    result.add hex[int(b and 0x0f)]

proc keyFromSeed*(seed: openArray[byte]): KeyPair = KeyPair()

proc newKey*(): KeyPair = KeyPair()
  ## No public half, which is how `msgsig` knows there is nothing to sign
  ## with. Deliberately not an exception: being unable to sign is a thing
  ## this client can carry on without, and a sign-in that threw here would
  ## take the whole connection with it.

proc sign*(key: KeyPair, msg: openArray[byte]): array[64, byte] =
  raise newException(CryptoError, "signing is not available in this build")

proc sign*(key: KeyPair, s: string): array[64, byte] =
  raise newException(CryptoError, "signing is not available in this build")
