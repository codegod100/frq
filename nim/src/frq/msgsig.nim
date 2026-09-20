## Signing a mutation so freeq will accept it.
##
## From `common/frq/msgsig.cljc`. What this is for: freeq answers an unsigned
## reaction or edit from a signed-in account with
## `FAIL TAGMSG SIGNATURE_REQUIRED`, so without this a signed-in reader can
## read and talk but cannot react at all.
##
## The key is per-connection and per-session: minted when the server ACKs the
## `freeq.at/msgsig` capability, announced with `MSGSIG`, and dropped when the
## connection goes — so a reconnect signs with a key the server has actually
## been told about.

import std/[algorithm, strutils, tables]
import frq/[crypto, trace]

type
  Signer* = object
    has*: bool
    did*: string
    kid*: string        ## how the server names this key
    key*: KeyPair

var signer: Signer

const b64urlAlphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

proc b64url*(bs: openArray[byte]): string =
  ## base64url of raw bytes, unpadded — how freeq writes a key and a
  ## signature.
  ##
  ## Over bytes and not over a string, which is the whole reason this is not
  ## `atproto.b64url`: a signature run through a String comes back re-encoded
  ## and no longer verifies.
  var i = 0
  while i < bs.len:
    let n = min(3, bs.len - i)
    let a = int(bs[i])
    let b = if n > 1: int(bs[i + 1]) else: 0
    let c = if n > 2: int(bs[i + 2]) else: 0
    let v = (a shl 16) or (b shl 8) or c
    for k in 0 .. n:
      result.add b64urlAlphabet[(v shr (6 * (3 - k))) and 0x3F]
    i += 3

proc forget*() =
  ## Drop the session key.
  signer = Signer()
  trace("msgsig", "key forgotten")

proc generate*(did: string): string =
  ## Mint a key for this connection and answer with its public half, base64url
  ## — which is what goes out as `MSGSIG <pub>`.
  ##
  ## A key with no public half is a build that cannot sign — the web one, so
  ## far, where Ed25519 is asynchronous and this is not. Nothing is claimed in
  ## that case: `signedIn` stays false, no MSGSIG goes out, and the server
  ## treats these lines as it treats a guest's. Better than announcing a key
  ## and then failing to sign with it.
  let key = newKey()
  if key.public.len == 0:
    signer = Signer()
    trace("msgsig", "no signing in this build; lines go out unsigned")
    return ""
  signer = Signer(has: true, did: did, key: key)
  signer.kid = b64url(signer.key.public)[0 ..< 16]
  trace("msgsig", "key for " & did & " kid=" & signer.kid)
  b64url(signer.key.public)

proc publicKey*(): string =
  if signer.has: b64url(signer.key.public) else: ""

proc signedIn*(): bool = signer.has

proc jsonString(s: string): string =
  ## Just the two escapes the canonical form can contain. Deliberately not a
  ## JSON encoder: both ends build this string themselves, and a library that
  ## escaped one more character than the other's would break every signature.
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    else: result.add c
  result.add "\""

proc canonical*(fields: Table[string, string]): string =
  ## The bytes that get signed: a JSON object with its keys in sorted order
  ## and no space in it.
  ##
  ## Both ends build this from the same fields and neither sends it — a
  ## signature over anything else is a signature over nothing.
  var keys: seq[string]
  for k in fields.keys: keys.add k
  keys.sort()
  result = "{"
  for i, k in keys:
    if i > 0: result.add ","
    result.add jsonString(k) & ":" & jsonString(fields[k])
  result.add "}"

proc bodyHash*(text: string): string =
  ## How a document names the text it covers: `sha256:` and the hash in
  ## lower-case hex. The signature is over the hash rather than the words, so
  ## a message of any length signs the same amount.
  "sha256:" & sha256(text).toHex

proc signingTarget*(target, ourDid, peerDid: string): string =
  ## How freeq names the place a mutation happens: a channel by its lowercased
  ## name, a DM by both DIDs in sorted order.
  ##
  ## "" where there is no way to say it — a DM with someone whose DID we have
  ## not seen yet — and an unsigned mutation is better than one signed over
  ## the wrong thing.
  if target.startsWith("#") or target.startsWith("&"):
    target.toLowerAscii
  elif ourDid.len > 0 and peerDid.len > 0:
    if ourDid <= peerDid: "dm:" & ourDid & "," & peerDid
    else: "dm:" & peerDid & "," & ourDid
  else:
    ""

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

proc eventId*(nowMs: int64): string =
  ## A fresh id for this mutation: ten characters of the clock, then sixteen
  ## of chance. Sortable like the msgids the server hands out, and unguessable
  ## enough that two clients cannot mint the same one.
  var t = nowMs
  var head = ""
  while head.len < 10:
    head = crockford[int(t mod 32)] & head
    t = t div 32
  result = head
  for b in randomBytes(16):
    result.add crockford[int(b) mod 32]

proc signBytes(msg: string): string =
  ## An Ed25519 signature over `msg`, as `ed25519:<kid>:<b64url>` — the shape
  ## freeq's `+freeq.at/sig` carries.
  if not signer.has: return ""
  "ed25519:" & signer.kid & ":" & b64url(sign(signer.key, msg))

proc mutationTags*(kind, target, subject, emoji, peerDid: string,
                   nowMs: int64): Table[string, string] =
  ## The two tags that make a mutation acceptable: the event id and the
  ## signature over it.
  ##
  ## Empty when this connection has no key — a guest signs nothing, and the
  ## server asks nothing of one.
  if not signer.has: return
  let venue = signingTarget(target, signer.did, peerDid)
  if venue.len == 0: return

  let id = eventId(nowMs)
  var fields = {"from": signer.did, "kind": kind, "msgid": id,
                "subject": subject, "target": venue}.toTable
  if emoji.len > 0 and kind != "delete":
    fields["emoji"] = emoji

  let sig = signBytes(canonical(fields))
  if sig.len == 0: return
  {"+freeq.at/eventid": id, "+freeq.at/sig": sig}.toTable

proc editTags*(target, rootMsgid, text, replyTo, peerDid: string,
               nowMs: int64): Table[string, string] =
  ## The tags that make a rewrite acceptable.
  ##
  ## An edit is a *message* document rather than a mutation one — it carries a
  ## body — so the fields are the message's own: who, which id, where, the
  ## hash of the new text, and `edit` naming the message being replaced.
  if not signer.has: return
  let venue = signingTarget(target, signer.did, peerDid)
  if venue.len == 0: return

  let id = eventId(nowMs)
  var fields = {"body": bodyHash(text), "edit": rootMsgid,
                "from": signer.did, "msgid": id, "target": venue}.toTable
  if replyTo.len > 0:
    fields["reply"] = replyTo

  let sig = signBytes(canonical(fields))
  if sig.len == 0: return
  {"+freeq.at/eventid": id, "+freeq.at/sig": sig}.toTable
