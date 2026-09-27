## The browser's signing, checked where it runs: compiled by `nim js`, in
## node, with the same TweetNaCl the page loads.
##
##   just test web        (or, from the repo root, what that recipe runs)
##
## The Nim suite cannot see this file — it builds for C, where `frq/crypto`
## is OpenSSL — so a SHA-256 that disagreed with everyone else's, or a
## signature freeq could not check, would pass every test there is.
##
## Here, beside `frq_web.nim`, rather than in `test/`: the project's own
## directory is searched first, and that is the only thing that makes
## `frq/crypto` mean this directory's and not `src/`'s.

import std/[sets, strutils, tables, unittest]
import frq/[atprotocore, crypto, handshake, ircparse, msgsig]

# TweetNaCl, as the page has it: on `self.nacl`, drawing on WebCrypto.
{.emit: """
globalThis.self = globalThis;
(0, eval)(require('fs').readFileSync('flutter/web/nacl-fast.min.js', 'utf8'));
""".}

proc fromHex(s: string): seq[byte] =
  for i in countup(0, s.high, 2): result.add byte(parseHexInt(s[i .. i + 1]))

proc verifies(msg: string, sig, pub: openArray[byte]): bool =
  ## TweetNaCl's own check, which is the same curve freeq's ed25519-dalek is.
  var m: seq[byte]
  for c in msg: m.add byte(c)
  {.emit: """
  `result` = globalThis.nacl.sign.detached.verify(Uint8Array.from(`m`),
    Uint8Array.from(`sig`), Uint8Array.from(`pub`));
  """.}

func unb64url(s: string): seq[byte] =
  const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  var acc, bits = 0
  for c in s:
    acc = (acc shl 6) or alphabet.find(c)
    bits += 6
    if bits >= 8:
      bits -= 8
      result.add byte((acc shr bits) and 0xff)

suite "SHA-256":
  test "the published vectors":
    check sha256("").toHex ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256("abc").toHex ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq").toHex ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

  test "across a block boundary, and a long one":
    check sha256('a'.repeat(1_000_000)).toHex ==
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

  test "over UTF-8, which is what a body hash is over":
    # The same bytes the desktop hashes: Nim strings are UTF-8 on both.
    check sha256("👍").toHex ==
      "5d57d39e6b7d8ea050980e6665bb1da357db14249d74e122f7d4e8cc2253beff"

suite "Ed25519":
  test "RFC 8032, test 1":
    let key = keyFromSeed(fromHex(
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
    check key.public.toHex ==
      "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    check sign(key, "").toHex ==
      "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"

  test "a fresh key has a public half, so the reader is signed in":
    check newKey().public.len == 32

suite "what freeq checks":
  test "the key is announced and named the way freeq names it":
    let pub = generate("did:plc:me")
    check signedIn()
    check unb64url(pub).len == 32
    check kidOf(unb64url(pub)).len == 22

  test "an edit's signature verifies over the document freeq rebuilds":
    let did = "did:plc:me"
    let pub = unb64url(generate(did))
    let tags = editTags("#Test", "01KYVT1W2P0000000000000000", "hello 👍", "",
                        "", 1_700_000_000_000)
    check tags.len == 2
    let parts = tags["+freeq.at/sig"].split(':')
    check parts[0] == "ed25519"
    check parts[1] == kidOf(pub)
    let doc = canonical({"body": bodyHash("hello 👍"),
                         "edit": "01KYVT1W2P0000000000000000",
                         "from": did, "msgid": tags["+freeq.at/eventid"],
                         "target": "#test"}.toTable)
    check verifies(doc, unb64url(parts[2]), pub)

  test "and so does a delete's":
    let did = "did:plc:me"
    let pub = unb64url(generate(did))
    let tags = mutationTags("delete", "#test", "m1", "", "", 1_700_000_000_000)
    let doc = canonical({"from": did, "kind": "delete",
                         "msgid": tags["+freeq.at/eventid"],
                         "subject": "m1", "target": "#test"}.toTable)
    check verifies(doc, unb64url(tags["+freeq.at/sig"].split(':')[2]), pub)

suite "signing in, in a browser":
  test "the key goes to the server before registration ends":
    # What this build never did: with no key it sent CAP END alone, freeq had
    # nothing on file for the reader, and every edit, delete and reaction
    # came back SIGNATURE_REQUIRED.
    let st = step(Session(did: "did:plc:me"), toHashSet(["freeq.at/msgsig"]),
                  parseLine(":s 903 n :ok"))
    check st.send.len == 2
    check st.send[0].startsWith("MSGSIG ")
    check unb64url(st.send[0]["MSGSIG ".len .. ^1]).len == 32
    check st.send[1] == "CAP END"
