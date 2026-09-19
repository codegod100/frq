## The C ABI, and nothing else.
##
## Every exported symbol is here so there is one file to read when asking what
## the Dart side can call. The logic lives under `frq/` in ordinary Nim with
## ordinary Nim types, which is what lets the tests test the rules rather than
## the marshalling.
##
## Two conventions, both of which the bindings in `flutter/src/frq/core/`
## wrap so no call site has to remember them:
##
## * Every returned string is the **caller's** to free, with `frq_free`. Nim's
##   allocator is not Dart's, so a `free()` on this side of the boundary is
##   undefined behaviour rather than a leak you can live with.
## * `frq_init` runs once before anything else. Nim's runtime needs setting up
##   and `--app:lib` does not do it for you on every platform.
##
## Answers that are not a single string come back as JSON. A struct would mean
## both sides agreeing on a memory layout, and a field added later would be a
## version skew that segfaults rather than one that fails; JSON costs a parse
## per call, which is nothing against the network round trip that produced the
## line being parsed.

import std/json
import frq/ircparse

proc NimMain() {.importc.}

var initialised = false

proc frq_init*() {.exportc, dynlib.} =
  ## Set Nim's runtime up. Idempotent, because a binding that guesses wrong
  ## about whether it has been called should be harmless rather than fatal.
  if not initialised:
    NimMain()
    initialised = true

proc dup(s: string): cstring =
  ## A copy of `s` that outlives this call, for the caller to `frq_free`.
  ## `allocShared0` and not `alloc0`: the Dart side may free it from a
  ## different thread than the one that made it.
  let n = s.len
  let p = cast[cstring](allocShared0(n + 1))
  if n > 0:
    copyMem(p, unsafeAddr s[0], n)
  p

proc frq_free*(p: cstring) {.exportc, dynlib.} =
  ## Free what one of the functions below returned. Null is fine.
  if p != nil:
    deallocShared(p)

proc frq_version*(): cstring {.exportc, dynlib.} =
  ## Static storage, deliberately: this one is NOT freed, and is the only
  ## exception to the rule above. It exists so a binding can check at load
  ## time that the library it found is the one it was built against.
  "0.1.0"

# ----------------------------------------------------------------- irc/parse

proc frq_irc_parse_line*(line: cstring): cstring {.exportc, dynlib.} =
  ## An IRC line as JSON: `{raw, tags, account, prefix, command, params}`.
  ##
  ## `tags`, `account` and `prefix` are JSON null where the line carried none,
  ## which is the distinction `frq.irc.parse` draws with nil and every caller
  ## of it depends on — a PRIVMSG from a server with no prefix is not the same
  ## line as one from a nick.
  if line == nil: return dup("null")
  let p = parseLine($line)
  var o = newJObject()
  o["raw"] = %p.raw
  o["tags"] = if p.hasTags: %p.tags else: newJNull()
  o["account"] = if p.hasAccount: %p.account else: newJNull()
  o["prefix"] = if p.hasPrefix: %p.prefix else: newJNull()
  o["command"] = %p.command
  o["params"] = %p.params
  dup($o)

proc frq_irc_tag_value*(tags, key: cstring): cstring {.exportc, dynlib.} =
  ## One tag's value, unescaped — or **null** where the tag is absent or
  ## empty, which IRCv3 says are the same thing. Null and not "" on purpose:
  ## see `tagValue`.
  if tags == nil or key == nil: return nil
  let (v, ok) = tagValue($tags, $key)
  if ok: dup(v) else: nil

proc frq_irc_unescape_tag*(v: cstring): cstring {.exportc, dynlib.} =
  if v == nil: return nil
  dup(unescapeTag($v))

proc frq_irc_escape_tag_value*(v: cstring): cstring {.exportc, dynlib.} =
  if v == nil: return dup("")
  dup(escapeTagValue($v))

proc frq_irc_nick_of*(prefix: cstring): cstring {.exportc, dynlib.} =
  if prefix == nil: return nil
  dup(nickOf($prefix))
