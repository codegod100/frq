## The broker flow, minus the waiting: a login URL out, a handoff payload in.
##
## Split from `oauth` for the reason `common/frq/oauth/core.cljc` was split
## from its two platform halves, which is the same reason it is back: building
## the URL and reading the payload are the same everywhere, and catching the
## answer is not. A desktop listens on a loopback port; a browser is *already*
## the thing being redirected, and reads the fragment it came back with.


import std/[base64, json, strutils]

const defaultBroker* = "https://auth.freeq.at"

type
  Tokens* = object
    ## What the broker hands back. `token` is single-use.
    token*, brokerToken*, nick*, did*, handle*: string

  OauthError* = object of CatchableError

# ----------------------------------------------------------------- the url

const hexDigits = "0123456789ABCDEF"

func unreserved(b: byte): bool =
  ## RFC 3986's unreserved set, by byte value: A-Z a-z 0-9 - _ . ~
  ##
  ## By number rather than by `isAlphaNumeric`, which would also say yes to
  ## é — and a percent-encoder that passes é through has not encoded
  ## anything.
  (b >= 48'u8 and b <= 57'u8) or (b >= 65'u8 and b <= 90'u8) or
  (b >= 97'u8 and b <= 122'u8) or b in [45'u8, 95'u8, 46'u8, 126'u8]

func urlEncode*(s: string): string =
  ## Percent-encode everything a handle could hold that a query string cannot.
  ##
  ## Over UTF-8 bytes rather than characters: a non-ASCII handle is several
  ## bytes and each is encoded on its own, which is what the spec says and
  ## what the broker expects.
  for c in s:
    let b = byte(c)
    if unreserved(b): result.add c
    else:
      result.add '%'
      result.add hexDigits[int(b shr 4)]
      result.add hexDigits[int(b and 0x0f)]

func trimmedBroker(broker: string): string =
  result = if broker.len > 0: broker else: defaultBroker
  while result.len > 0 and result[^1] == '/': result.setLen(result.len - 1)

func loginUrl*(broker, handle, returnTo: string): string =
  ## Where the browser goes. A leading `@` on the handle is the reader typing
  ## it the way it appears beside a message, not part of it.
  var h = handle.strip()
  if h.startsWith("@"): h = h[1 .. ^1]
  trimmedBroker(broker) & "/auth/login?handle=" & urlEncode(h) &
    "&return_to=" & urlEncode(returnTo)

func brokerHost*(broker: string): string =
  var b = trimmedBroker(broker)
  if b.startsWith("https://"): b = b[8 .. ^1]
  elif b.startsWith("http://"): b = b[7 .. ^1]
  b.split('/')[0]

# ------------------------------------------------------------- the handoff

proc b64urlDecode(s: string): string =
  var t = s.replace("-", "+").replace("_", "/")
  while t.len mod 4 != 0: t.add '='
  try: decode(t) except CatchableError: ""

proc tokensOf*(payload: string): Tokens =
  ## The broker's base64url JSON payload, as fields.
  ##
  ## Both tokens or none: a payload missing either is the broker reporting a
  ## failure, and it puts the reason in `error`.
  let raw = b64urlDecode(payload.strip())
  let j = try: parseJson(raw)
          except CatchableError:
            raise newException(OauthError, "Malformed sign-in payload")
  result = Tokens(token: j{"token"}.getStr(),
                  brokerToken: j{"broker_token"}.getStr(),
                  nick: j{"nick"}.getStr(),
                  did: j{"did"}.getStr(),
                  handle: j{"handle"}.getStr())
  if result.token.len == 0 or result.brokerToken.len == 0:
    let e = j{"error"}.getStr()
    raise newException(OauthError,
                       if e.len > 0: e else: "Malformed sign-in payload")

