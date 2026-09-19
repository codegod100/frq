## What this client says back to a server, given what a server says to it.
##
## The reducer's answer to an incoming line was the largest untested thing in
## the program: reachable only through a real socket, so nothing checked it.
## That is where the missing CHATHISTORY request sat through the whole port —
## every room came back with no history and the only comment about it was in
## another module, describing behaviour that had never been ported.
##
## `conn.feed` puts a line in as though the server had sent it; `tryOutbound`
## reads what went out. No socket at either end.

import std/[json, sequtils, strutils, tables, unittest]
import frq/[cells, model, reducer, rooms]
import frq/conn as tr

proc sent(): seq[string] =
  ## Everything queued to go out, drained.
  while true:
    let (ok, line) = tr.tryOutbound()
    if not ok: break
    result.add line

proc say(lines: varargs[string]) =
  for l in lines: tr.feed(l)
  drain()

proc reset() =
  app = initState()
  app.formNick = "alice"
  discard sent()

proc joined(room: string) =
  ## The server putting us in a room, which is how every one of them starts —
  ## a JOIN we sent, or one freeq made for a signed-in account at
  ## registration. A 366 for a room this client has never heard of is not
  ## ours and is left alone.
  say(":alice!a@h JOIN " & room)
  discard sent()

suite "asking for the backlog":
  setup: reset()

  test "end of NAMES in an empty room asks for history":
    joined("#freeq")
    # freeq re-joins an authenticated user's channels at registration and
    # leaves the backlog for the client to ask for. A room that arrives this
    # way has no history coming unless we ask, which is why a signed-in
    # connection showed new lines and nothing else.
    say(":server 366 alice #freeq :End of /NAMES list")
    check app.rooms.hasKey("#freeq")
    check sent().anyIt(it.startsWith("CHATHISTORY LATEST #freeq * "))

  test "and asks for a hundred lines of it":
    joined("#freeq")
    say(":server 366 alice #freeq :End of /NAMES list")
    check "CHATHISTORY LATEST #freeq * 100" in sent()

  test "a room that already has lines is not asked twice":
    # The replay comes back as ordinary PRIVMSGs; asking again is a second
    # copy of the same history crossing the wire to be thrown away.
    joined("#freeq")
    say(":bob!b@h PRIVMSG #freeq :already here")
    discard sent()
    say(":server 366 alice #freeq :End of /NAMES list")
    check not sent().anyIt(it.startsWith("CHATHISTORY"))

  test "a room this client was never put in is not asked about":
    # Not a room of ours: 366 for it arrives before any JOIN, and answering
    # it would ask a server for the history of somewhere we are not.
    say(":server 366 alice #nowhere :End of /NAMES list")
    check not app.rooms.hasKey("#nowhere")
    check not sent().anyIt(it.startsWith("CHATHISTORY"))

suite "the rest of the conversation":
  setup: reset()

  test "a PING is answered with its own token":
    say("PING :abc123")
    check "PONG :abc123" in sent()

  test "our own JOIN marks the room joined; somebody else's adds a name":
    say(":alice!a@h JOIN #freeq")
    check app.rooms["#freeq"].joined
    say(":bob!b@h JOIN #freeq")
    check app.rooms["#freeq"].users.hasKey("bob")

  test "NAMES arrives over several lines and lands in one go":
    joined("#freeq")
    say(":server 353 alice = #freeq :alice @bob",
        ":server 353 alice = #freeq :carol")
    # Still pending: replacing the list per line empties the panel and
    # refills it a name at a time.
    check app.rooms["#freeq"].users.len == 0
    say(":server 366 alice #freeq :End of /NAMES list")
    check app.rooms["#freeq"].users.len == 3

  test "a replayed line lands in the room it names":
    joined("#freeq")
    say(":server 366 alice #freeq :End of /NAMES list",
        ":bob!b@h PRIVMSG #freeq :an old line")
    check app.rooms["#freeq"].messages.anyIt(it.text == "an old line")

  test "a message to us is filed under whoever sent it":
    say(":bob!b@h PRIVMSG alice :a direct word")
    check app.rooms.hasKey("bob")
    check app.rooms["bob"].messages[^1].text == "a direct word"

suite "who is who":
  setup: reset()

  test "WHO reports the whole DID where the hostmask has eight characters":
    # `freeq/plc/ngokl2gn` is enough to tell two people apart and not enough
    # to look either of them up. The realname field carries all of it.
    say(":irc.freeq.at 352 alice #freeq ~u freeq/plc/ngokl2gn irc.freeq.at " &
        "nandi.uk H :0 did:plc:ngokl2gnmpbvuvrfckja3g7p")
    check app.dids["nandi.uk"] == "did:plc:ngokl2gnmpbvuvrfckja3g7p"

  test "an agent signs with a key, and that is an identity too":
    say(":irc.freeq.at 352 alice #freeq ~u freeq/key/z6Mkp5we irc.freeq.at " &
        "cartographer H :0 did:key:z6Mkp5wegrxZR62h54HwR329yz7TJ8Ccx4shCpSB")
    check app.dids["cartographer"].startsWith("did:key:")

  test "a guest has none, and is not recorded as having one":
    # freeq puts the literal "IRC User" there for an unauthenticated
    # connection, which is not a DID and must not be stored as one.
    say(":irc.freeq.at 352 alice #freeq ~u freeq/guest irc.freeq.at " &
        "adam12 H :0 IRC User")
    check not app.dids.hasKey("adam12")

  test "WHOIS answers for one nick the same way":
    say(":irc.freeq.at 330 alice zapnap did:plc:k2n3e2vsabcdefghijklmnop " &
        ":is authenticated as")
    check app.dids["zapnap"] == "did:plc:k2n3e2vsabcdefghijklmnop"

  test "and the room is asked who is in it once it has arrived":
    joined("#freeq")
    say(":server 366 alice #freeq :End of /NAMES list")
    check "WHO #freeq" in sent()

suite "opening a profile":
  setup: reset()

  test "uses what WHO reported for a nick that is not a handle":
    say(":irc.freeq.at 352 alice #freeq ~u freeq/plc/k2n3e2vs irc.freeq.at " &
        "zapnap H :0 did:plc:k2n3e2vsabcdefghijklmnop")
    dispatch(%*{"id": "profile.open:zapnap:"})
    check app.profileViewing.actor == "did:plc:k2n3e2vsabcdefghijklmnop"

  test "asks the server about somebody it has never seen":
    dispatch(%*{"id": "profile.open:stranger:"})
    check "WHOIS stranger" in sent()

  test "and what the message itself knew still wins":
    dispatch(%*{"id": "profile.open:bob:did:plc:fromtheaccounttag"})
    check app.profileViewing.actor == "did:plc:fromtheaccounttag"
