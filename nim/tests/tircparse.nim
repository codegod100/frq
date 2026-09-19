## The IRC wire format, tested against the cases that cost something.
##
## These are not a transcription of the Clojure's tests, because it had none —
## which is half the argument for the move. Every case here is either a rule
## IRCv3 states or a bug the comments in `common/frq/irc/parse.cljc` record
## having been paid for once already.

import std/unittest
import frq/ircparse

suite "parseLine":
  test "a bare line":
    let p = parseLine("PING :12345")
    check p.command == "PING"
    check p.params == @["12345"]
    check not p.hasPrefix
    check not p.hasTags

  test "a prefix is split off and the command upcased":
    let p = parseLine(":nick!user@host privmsg #chan :hello there")
    check p.prefix == "nick!user@host"
    check p.hasPrefix
    check p.command == "PRIVMSG"
    check p.params == @["#chan", "hello there"]

  test "the trailing parameter keeps its spaces and its colons":
    let p = parseLine(":a!b@c PRIVMSG #chan :look: a b  c")
    check p.params == @["#chan", "look: a b  c"]

  test "no trailing parameter at all":
    let p = parseLine(":a!b@c JOIN #chan")
    check p.params == @["#chan"]

  test "an empty trailing parameter is a parameter":
    # `:` with nothing after it is how a client sends an empty topic, and
    # dropping it turns a clear into a no-op.
    let p = parseLine(":a!b@c TOPIC #chan :")
    check p.params == @["#chan", ""]

  test "tags are taken off the front":
    let p = parseLine("@time=2026-01-01T00:00:00Z;account=alice :a!b@c PRIVMSG #chan :hi")
    check p.hasTags
    check p.tags == "time=2026-01-01T00:00:00Z;account=alice"
    check p.account == "alice"
    check p.command == "PRIVMSG"
    check p.params == @["#chan", "hi"]

  test "a line with tags and no account":
    let p = parseLine("@time=x :a!b@c PRIVMSG #chan :hi")
    check p.hasTags
    check not p.hasAccount

  test "trailing whitespace is trimmed but leading structure is not":
    let p = parseLine("PING :12345\r\n")
    check p.raw == "PING :12345"
    check p.params == @["12345"]

  test "raw is what arrived, not what we made of it":
    let p = parseLine("@a=1 :n!u@h PRIVMSG #c :x  ")
    check p.raw == "@a=1 :n!u@h PRIVMSG #c :x"

  test "runs of spaces in the head do not become empty parameters":
    let p = parseLine(":a!b@c PRIVMSG   #chan   :hi")
    check p.params == @["#chan", "hi"]

  test "a line that is only tags does not throw":
    # The Clojure indexes with `subs` on a nil `index-of` here and dies. It
    # cannot arrive from a conforming server, but a parser reading a socket
    # answers malformed input with a value rather than an exception.
    let p = parseLine("@only=tags")
    check p.hasTags
    check p.tags == "only=tags"
    check p.command == ""

  test "an empty line":
    let p = parseLine("")
    check p.command == ""
    check p.params.len == 0

suite "unescapeTag":
  test "the five escapes":
    check unescapeTag("a\\:b") == "a;b"
    check unescapeTag("a\\sb") == "a b"
    check unescapeTag("a\\\\b") == "a\\b"
    check unescapeTag("a\\rb") == "a\rb"
    check unescapeTag("a\\nb") == "a\nb"

  test "an unknown escape is the character itself":
    check unescapeTag("a\\qb") == "aqb"

  test "a trailing backslash is kept rather than eating the terminator":
    check unescapeTag("ab\\") == "ab\\"

  test "a reaction tally survives the trip":
    # The bug this function exists for: three tallies, not one.
    check unescapeTag("x\\:alice\\:bob") == "x;alice;bob"

suite "escapeTagValue":
  test "round-trips everything unescapeTag undoes":
    for s in ["plain", "a;b", "a b", "a\\b", "a\r\nb", "", "😀", "a;;b"]:
      check unescapeTag(escapeTagValue(s)) == s

  test "a backslash is not double-escaped":
    check escapeTagValue("a\\b") == "a\\\\b"

suite "tagValue":
  test "a present value":
    check tagValue("a=1;b=2", "b") == ("2", true)

  test "an absent tag":
    check tagValue("a=1", "b") == ("", false)

  test "an empty value and a bare key are both absent":
    # IRCv3 says `key` and `key=` mean the same thing, and a caller asking
    # `tagValue` is asking whether a fact is there. `+reply=` on a line
    # answering nothing used to put a reply chip above it.
    check tagValue("a=;b=2", "a") == ("", false)
    check tagValue("a;b=2", "a") == ("", false)

  test "the value is unescaped":
    check tagValue("t=a\\sb", "t") == ("a b", true)

  test "a key that is a prefix of another does not match it":
    check tagValue("account-x=1;account=2", "account") == ("2", true)

  test "a value containing = keeps the rest of it":
    check tagValue("t=a=b", "t") == ("a=b", true)

suite "nickOf":
  test "a full prefix":
    check nickOf("nick!user@host") == "nick"

  test "a prefix that is only a nick":
    check nickOf("nick") == "nick"

  test "a server prefix has no bang and comes back whole":
    check nickOf("irc.freeq.at") == "irc.freeq.at"
