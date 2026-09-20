## Who someone is, behind the nick on a line.
##
## From `common/frq/profile.cljc`. sleek's peer profile modal, as a panel:
## the picture at a size worth looking at, the display name and handle, the
## DID, whatever bio and counts Bluesky holds, and a way through to their
## profile on the web.
##
## One fetch per person, kept for the run — a profile is looked at repeatedly
## and changes on nobody's timescale. Guests have no identity to fetch, so for
## them the panel is the nick and a line saying so, which is the honest answer
## rather than a spinner that never lands.
##
## One gesture opens it: a press. A pointer resting on a face used to open it
## too, which made the card something that could arrive without being asked
## for — crossing a column of faces on the way to the scrollbar flickered one
## open per row.
##
## The Clojure has a fetch seam here because the two compilers disagreed about
## HTTP. Nim has one client, so the seam is gone and `fetch` simply asks.

import std/[json, strutils, tables]
from std/unicode import runeLen, runeSubStr


type
  ProfileStatus* = enum
    psLoading = "loading", psReady = "ready", psFailed = "failed"

  Profile* = object
    status*: ProfileStatus
    did*, avatar*, handle*, displayName*, description*: string
    followers*, follows*, posts*: int

var cache: Table[string, Profile]

func isHandle*(nick: string): bool =
  ## Whether this nick is an AT Protocol handle, and so worth a lookup.
  ##
  ## Domain shape, per the handle grammar: dot-separated labels that begin
  ## with a letter or digit and may then carry hyphens, and a final label of
  ## letters only. Scanned rather than matched: `std/re` is PCRE, which means
  ## a `libpcre.so` the machine running this may not have — and it did not,
  ## the first time this shipped. `ircparse` and `clock` scan for the same
  ## reason.
  if nick.len == 0: return false
  var
    labels = 0
    labelLen = 0
    lastAllAlpha = true
  for i, c in nick:
    if c == '.':
      if labelLen == 0: return false     # empty label: leading, doubled or trailing dot
      labels.inc
      labelLen = 0
      lastAllAlpha = true
    elif c in {'A'..'Z', 'a'..'z'}:
      labelLen.inc
    elif c in {'0'..'9'}:
      labelLen.inc
      lastAllAlpha = false
    elif c == '-':
      if labelLen == 0: return false     # a label may not open with a hyphen
      labelLen.inc
      lastAllAlpha = false
    else:
      return false
  # The last label is the TLD: at least two characters, and all letters.
  labels > 0 and labelLen >= 2 and lastAllAlpha

func isAgent*(actor: string): bool =
  ## Whether this identity is a `did:key:` — an agent that signs with a key
  ## of its own rather than an account in somebody's PDS.
  ##
  ## There is no Bluesky profile behind one, so asking for it is a request
  ## that can only 400. freeq has several in its rooms; they are not broken
  ## accounts and should not be reported as one.
  actor.startsWith("did:key:")

proc actorFor*(did, nick: string): string =
  ## The identity to look a profile up by, or "" when there is none.
  ##
  ## A DID from the message's `account` tag when the server sent one — it is
  ## the identity itself, and holds whatever the nick happens to be today.
  ## Otherwise the nick, but only when it is handle-shaped: freeq gives an
  ## authenticated user their handle by default, while `sleek5209` is a guest
  ## with no profile.
  if did.startsWith("did:"): did
  elif isHandle(nick): nick
  else: ""

proc thumbnailUrl*(url: string): string =
  ## The CDN's full-size avatar URL as a 128-pixel PNG.
  ##
  ## Asking for the size we paint keeps a 170KB portrait from being downloaded
  ## to draw at 24 points.
  if url.len == 0: return ""
  var u = url.replace("/img/avatar/plain/", "/img/avatar_thumbnail/plain/")
  # Drop a trailing @jpeg/@png before adding our own.
  let at = u.rfind('@')
  if at > 0 and u[at + 1 .. ^1].allCharsInSet({'a' .. 'z'}):
    u = u[0 ..< at]
  u & "@png"

proc parseProfile*(body: JsonNode): Profile =
  ## The fields the panel paints, out of an `app.bsky.actor.getProfile` body.
  Profile(status: psReady,
          did: body{"did"}.getStr(),
          avatar: thumbnailUrl(body{"avatar"}.getStr()),
          handle: body{"handle"}.getStr(),
          displayName: body{"displayName"}.getStr().strip(),
          description: body{"description"}.getStr().strip(),
          followers: body{"followersCount"}.getInt(),
          follows: body{"followsCount"}.getInt(),
          posts: body{"postsCount"}.getInt())

proc remember*(actor: string, p: Profile) =
  ## Put a profile in the cache. For `profilefetch`, which is the only thing
  ## that has one to put — the cache lives here because this is the side the
  ## screens read, and a screen must never reach the side that fetches.
  cache[actor] = p

proc known*(actor: string): bool = cache.hasKey(actor)

proc entry*(actor: string): (Profile, bool) =
  ## What is known about this person right now, and whether anything is.
  if cache.hasKey(actor): (cache[actor], true)
  else: (Profile(), false)

proc avatarFor*(actor: string, alsoKnownAs = ""): string =
  ## The face to paint for this identity, or "" where there is not one yet.
  ## A lookup and never a fetch: this is called from the render path.
  ##
  ## Two names because a person has two here, and which one the screen uses
  ## changes underneath them. Before WHO answers, a handle-shaped nick is its
  ## own actor; afterwards the actor is the DID. Without the fallback the
  ## face would appear on the first message, vanish the moment WHO arrived,
  ## and come back when the second fetch landed.
  if actor.len > 0:
    let p = cache.getOrDefault(actor)
    if p.status == psReady and p.avatar.len > 0: return p.avatar
  if alsoKnownAs.len > 0 and alsoKnownAs != actor:
    let q = cache.getOrDefault(alsoKnownAs)
    if q.status == psReady: return q.avatar
  ""

proc setProfileForTest*(actor, avatar: string) =
  ## A profile that has arrived, without a network. For the tests that are
  ## about what the screen does with one.
  cache[actor] = Profile(status: psReady, avatar: avatar, handle: actor)

proc forgetProfiles*() =
  ## For a test that wants a known starting point.
  cache.clear()

proc webUrl*(p: Profile): string =
  ## Their profile on the web, by handle where there is one and DID otherwise.
  let who = if p.handle.strip().len > 0: p.handle.strip() else: p.did
  if who.len == 0: "" else: "https://bsky.app/profile/" & who.strip(chars = {'@'})

proc statsLine*(p: Profile): string =
  ## "12 followers · 34 following · 56 posts", or "" when none are known.
  var parts: seq[string]
  if p.followers > 0: parts.add $p.followers & " followers"
  if p.follows > 0: parts.add $p.follows & " following"
  if p.posts > 0: parts.add $p.posts & " posts"
  parts.join(" · ")

proc truncate*(s: string, max: int): string =
  ## A bio cut to `max` characters, keeping its line breaks — the height of a
  ## multi-line bio is part of what it says.
  # Runes, not bytes: a bio is exactly where emoji live, and a byte slice
  # lands inside one and makes mojibake where an ellipsis was wanted. The
  # third time this has come up in this port.
  let t = s.strip()
  if t.runeLen <= max: t else: t.runeSubStr(0, max - 1) & "…"

