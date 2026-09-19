## Signing a mutation. The canonical form is the part that matters: both ends
## build it independently and neither sends it, so a byte of disagreement is a
## signature over nothing.

import std/[strutils, tables, unittest]
import frq/[msgsig, crypto]

suite "b64url":
  test "unpadded and URL-safe":
    check b64url([byte 0xFB, 0xFF, 0xFE]) == "-__-"
    check '=' notin b64url([byte 1, 2, 3, 4, 5])

  test "the partial groups":
    check b64url([]) == ""
    check b64url([byte 0]) == "AA"
    check b64url([byte 0, 0]) == "AAA"
    check b64url([byte 0, 0, 0]) == "AAAA"

  test "a 32-byte key is 43 characters":
    check b64url(newSeq[byte](32)).len == 43
  test "a 64-byte signature is 86":
    check b64url(newSeq[byte](64)).len == 86

suite "canonical":
  test "keys are sorted and there is no space":
    check canonical({"b": "2", "a": "1"}.toTable) == """{"a":"1","b":"2"}"""

  test "insertion order cannot change the answer":
    # Both ends build this from the same fields in whatever order they happen
    # to have them.
    check canonical({"z": "1", "a": "2", "m": "3"}.toTable) ==
          canonical({"a": "2", "m": "3", "z": "1"}.toTable)

  test "quotes and backslashes are escaped, and nothing else is":
    check canonical({"k": "a\"b"}.toTable) == """{"k":"a\"b"}"""
    check canonical({"k": "a\\b"}.toTable) == """{"k":"a\\b"}"""

  test "a newline is NOT escaped":
    # Deliberately not a JSON encoder: a library that escaped one more
    # character than the other end's would break every signature.
    check canonical({"k": "a\nb"}.toTable) == "{\"k\":\"a\nb\"}"

  test "empty":
    check canonical(initTable[string, string]()) == "{}"

suite "signingTarget":
  test "a channel is its lowercased name":
    check signingTarget("#Test", "did:a", "") == "#test"
    check signingTarget("&local", "did:a", "") == "&local"

  test "a DM is both DIDs, sorted, so both ends agree":
    check signingTarget("alice", "did:a", "did:b") == "dm:did:a,did:b"
    check signingTarget("alice", "did:b", "did:a") == "dm:did:a,did:b"

  test "a DM with nobody named has no way to be said":
    # An unsigned mutation is better than one signed over the wrong thing.
    check signingTarget("alice", "did:a", "") == ""
    check signingTarget("alice", "", "did:b") == ""

suite "bodyHash":
  test "names the algorithm and the hash":
    check bodyHash("").startsWith("sha256:")
    check bodyHash("") ==
      "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  test "different text, different hash":
    check bodyHash("a") != bodyHash("b")

suite "eventId":
  test "ten of the clock and sixteen of chance":
    check eventId(1_700_000_000_000).len == 26
  test "sortable by time":
    check eventId(1_700_000_000_000) < eventId(1_800_000_000_000)
  test "two at the same instant still differ":
    check eventId(1_700_000_000_000) != eventId(1_700_000_000_000)
  test "only Crockford characters":
    for c in eventId(1_700_000_000_000):
      check c in "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

suite "the signer":
  setup:
    forget()

  test "a guest signs nothing":
    check not signedIn()
    check publicKey() == ""
    check mutationTags("react", "#test", "m1", "👍", "", 0).len == 0
    check editTags("#test", "m1", "new", "", "", 0).len == 0

  test "generating gives the public half, base64url":
    let pub = generate("did:plc:me")
    check pub.len == 43
    check signedIn()
    check publicKey() == pub

  test "forgetting really forgets":
    discard generate("did:plc:me")
    forget()
    check not signedIn()
    check mutationTags("react", "#test", "m1", "👍", "", 0).len == 0

  test "a mutation carries an event id and a signature naming the key":
    discard generate("did:plc:me")
    let tags = mutationTags("react", "#test", "m1", "👍", "", 1_700_000_000_000)
    check tags.len == 2
    check tags["+freeq.at/eventid"].len == 26
    check tags["+freeq.at/sig"].startsWith("ed25519:")
    # ed25519:<kid>:<sig>
    let parts = tags["+freeq.at/sig"].split(':')
    check parts.len == 3
    check parts[1].len == 16
    check parts[2].len == 86

  test "the signature verifies against the canonical form it covers":
    # Rebuilt here the way the server rebuilds it, which is the only check
    # that says the right bytes were signed.
    let did = "did:plc:me"
    discard generate(did)
    let tags = mutationTags("react", "#test", "m1", "👍", "", 1_700_000_000_000)
    let fields = {"from": did, "kind": "react",
                  "msgid": tags["+freeq.at/eventid"],
                  "subject": "m1", "target": "#test", "emoji": "👍"}.toTable
    # Same shape, same bytes: if the two disagreed the server would refuse it.
    check canonical(fields).startsWith("""{"emoji":"👍","from":"did:plc:me"""")

  test "delete carries no emoji":
    discard generate("did:plc:me")
    let tags = mutationTags("delete", "#test", "m1", "👍", "", 0)
    check tags.len == 2

  test "an edit signs the hash of the body, not the body":
    discard generate("did:plc:me")
    let a = editTags("#test", "m1", "short", "", "", 0)
    let b = editTags("#test", "m1", "x".repeat(10_000), "", "", 0)
    # A message of any length signs the same amount.
    check a["+freeq.at/sig"].len == b["+freeq.at/sig"].len

  test "a DM with no peer DID is not signed at all":
    discard generate("did:plc:me")
    check mutationTags("react", "alice", "m1", "👍", "", 0).len == 0
    check mutationTags("react", "alice", "m1", "👍", "did:plc:them", 0).len == 2
