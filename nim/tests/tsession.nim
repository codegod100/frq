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

import std/[json, options, sequtils, strutils, tables, unittest]
import frq/[cells, model, profile, reducer, rooms]
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

  test "a reconnect that brings no backlog asks, though the buffer is full":
    # freeq answers a reconnect by reclaiming the ghost session: JOIN and
    # NAMES, and no replay between them. The buffer still holds the lines
    # from before the drop, and testing it for emptiness is what left every
    # line said while we were away missing.
    joined("#freeq")
    say("@msgid=a1 :bob!b@h PRIVMSG #freeq :before the drop",
        ":server 366 alice #freeq :End of /NAMES list")
    discard sent()
    joined("#freeq")
    say(":server 366 alice #freeq :End of /NAMES list")
    check "CHATHISTORY LATEST #freeq * 100" in sent()

  test "a rejoin that replays lines we already hold does not ask again":
    joined("#freeq")
    say("@msgid=a1 :bob!b@h PRIVMSG #freeq :before the drop",
        ":server 366 alice #freeq :End of /NAMES list")
    discard sent()
    joined("#freeq")
    say("@msgid=a1 :bob!b@h PRIVMSG #freeq :before the drop",
        ":server 366 alice #freeq :End of /NAMES list")
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

  test "an empty late notice does not create a phantom latest row":
    joined("#freeq")
    say("@time=2026-09-23T19:00:00Z :bob!b@h PRIVMSG #freeq :current")
    say("@time=2026-09-17T19:00:00Z :server NOTICE #freeq :")
    let messages = app.rooms["#freeq"].messages.filterIt(not it.system)
    check messages.len == 1
    check messages[0].text == "current"

  test "a late history replay is placed by server time":
    joined("#freeq")
    say("@time=2026-09-23T19:00:00Z :bob!b@h PRIVMSG #freeq :current",
        "@time=2026-09-17T19:00:00Z :carol!c@h PRIVMSG #freeq :older")
    let messages = app.rooms["#freeq"].messages.filterIt(not it.system)
    check messages.mapIt(it.text) == @["older", "current"]

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

suite "faces":
  setup:
    reset()
    forgetProfiles()

  test "learning a DID starts the face on its way, without waiting for it":
    # `want` is not `fetch`: a room of twelve is twelve HTTPS round trips,
    # and this is the thread that answers every keystroke.
    say(":irc.freeq.at 352 alice #freeq ~u freeq/plc/ngokl2gn irc.freeq.at " &
        "nandi.uk H :0 did:plc:ngokl2gnmpbvuvrfckja3g7p")
    let (p, known) = entry("did:plc:ngokl2gnmpbvuvrfckja3g7p")
    check known
    check p.status == psLoading

  test "and nothing is painted for one that has not arrived":
    say(":irc.freeq.at 352 alice #freeq ~u freeq/plc/ngokl2gn irc.freeq.at " &
        "nandi.uk H :0 did:plc:ngokl2gnmpbvuvrfckja3g7p")
    check avatarFor("did:plc:ngokl2gnmpbvuvrfckja3g7p") == ""

  test "a handle-shaped nick is asked for as soon as it speaks":
    # Before WHO has answered, the screen looks a face up under the handle —
    # so that is the name it has to be asked for under. Asking only when a
    # DID turned up is why a face appeared only after opening the profile by
    # hand, which asks under the handle.
    say(":nandi.uk!u@freeq/plc/ngokl2gn PRIVMSG #freeq :hello")
    check entry("nandi.uk")[1]
    check entry("nandi.uk")[0].status == psLoading

  test "and once WHO has answered, under the DID the screen then uses":
    say(":irc.freeq.at 352 alice #freeq ~u freeq/plc/ngokl2gn irc.freeq.at " &
        "nandi.uk H :0 did:plc:ngokl2gnmpbvuvrfckja3g7p",
        ":nandi.uk!u@freeq/plc/ngokl2gn PRIVMSG #freeq :hello")
    check entry("did:plc:ngokl2gnmpbvuvrfckja3g7p")[1]

  test "a guest nick is nobody to look up":
    # `sleek5209` is not a handle and has no DID; there is no profile behind
    # it and a request for one can only fail.
    say(":sleek5209!u@freeq/guest PRIVMSG #freeq :hello")
    check not entry("sleek5209")[1]

  test "and a system line is not somebody speaking":
    say(":alice!a@h JOIN #freeq")
    check not entry("*")[1]

  test "the face does not blink when WHO changes which name is the actor":
    # The handle's profile is what is cached when the first message lands;
    # the actor becomes the DID a moment later. Without the fallback there is
    # a hole between the two.
    say(":nandi.uk!u@freeq/plc/ngokl2gn PRIVMSG #freeq :hello")
    setProfileForTest("nandi.uk", "https://cdn/face.png")
    check avatarFor("did:plc:ngokl2gnmpbvuvrfckja3g7p", "nandi.uk") ==
          "https://cdn/face.png"

  test "an agent is never asked about":
    # `did:key:` has no Bluesky profile, so a request for one can only 400.
    say(":irc.freeq.at 352 alice #freeq ~u freeq/key/z6Mkp5we irc.freeq.at " &
        "cartographer H :0 did:key:z6Mkp5wegrxZR62h54HwR329yz7TJ8Ccx4sh")
    check not entry("did:key:z6Mkp5wegrxZR62h54HwR329yz7TJ8Ccx4sh")[1]

suite "how big the window is":
  setup: reset()

  test "the host says, in the value, which is where the renderer puts it":
    # Nothing sent this until it was noticed: `windowWidth` was zero on every
    # window there had ever been, so `wide` was always false and the whole
    # side-by-side layout was unreachable.
    #
    # The value and not the id, and this test says so because the first one
    # did not: it passed against a reducer that read the id only, while the
    # renderer sent a value nobody looked at.
    dispatch(%*{"id": "window.size", "value": "1280x760"})
    check app.windowWidth == 1280
    check app.windowHeight == 760
    check app.wide

  test "or after the colon, for a console or a test that types it":
    dispatch(%*{"id": "window.size:1280x760"})
    check app.wide

  test "and a narrow one is not wide":
    dispatch(%*{"id": "window.size", "value": "420x800"})
    check not app.wide

  test "nonsense does not move it":
    dispatch(%*{"id": "window.size", "value": "1280x760"})
    dispatch(%*{"id": "window.size", "value": "banana"})
    dispatch(%*{"id": "window.size", "value": "0x0"})
    check app.windowWidth == 1280

suite "being renamed":
  setup: reset()

  test "the server settling our name is the name we use":
    # freeq hands a guest a name of its choosing and settles a signed-in
    # connection on the account's. Nothing followed that, so a reader could
    # sign in with Bluesky and go on being `frq-guest` — and every "is this
    # mine?" test on a line said no, because it compares nicks.
    joined("#freeq")
    say(":alice!a@h NICK alice.bsky.social")
    check app.formNick == "alice.bsky.social"

  test "and somebody else's rename follows them round the room":
    joined("#freeq")
    say(":irc.freeq.at 353 alice = #freeq :alice @bob carol",
        ":irc.freeq.at 366 alice #freeq :End of /NAMES list",
        ":bob!b@h NICK robert")
    check app.rooms["#freeq"].users.hasKey("robert")
    check not app.rooms["#freeq"].users.hasKey("bob")

  test "with the mode they had":
    # An op who renames is still an op; dropping the prefix would take their
    # mode off the list until the next NAMES.
    joined("#freeq")
    say(":irc.freeq.at 353 alice = #freeq :alice @bob",
        ":irc.freeq.at 366 alice #freeq :End of /NAMES list",
        ":bob!b@h NICK robert")
    check app.rooms["#freeq"].users["robert"] == "@"

  test "and somebody we have never seen changes nothing":
    joined("#freeq")
    say(":stranger!s@h NICK someoneelse")
    check app.formNick == "alice"

suite "sending a picture":
  setup:
    reset()
    joined("#freeq")
    dispatch(%*{"id": "room.open:#freeq"})
    discard sent()

  test "the button asks the host, and says who is asking":
    # It had no handler at all: the press traced "no handler" and nothing
    # happened, which is what "the image upload icon is not working" was.
    #
    # A guest cannot upload — freeq files one under an account — so the
    # question is only asked when there is one.
    check wantedPicture() == ""
    dispatch(%*{"id": "image.pick"})
    check wantedPicture() == ""          # no session yet: refused, with a reason
    check app.hasError

    app.hasError = false
    dispatch(%*{"id": "window.size", "value": "1280x800"})
    setSessionForTest("did:plc:abc", "https://pds.example")
    dispatch(%*{"id": "image.pick"})
    let want = parseJson(wantedPicture())
    check want["did"].getStr() == "did:plc:abc"
    check want["channel"].getStr() == "#freeq"
    check want["host"].getStr() == "irc.freeq.at"

  test "and is asked once, so one dialog opens":
    setSessionForTest("did:plc:abc", "https://pds.example")
    dispatch(%*{"id": "image.pick"})
    check wantedPicture().len > 0
    check wantedPicture() == ""

  test "the URL that comes back goes out in the line":
    # This is how a picture travels on IRC: the wire carries text, and every
    # client finds the picture by looking for a link in it. It used to be put
    # on the local copy alone, so a picture appeared for the sender and for
    # nobody else.
    dispatch(%*{"id": "attachment.ready:https://irc.freeq.at/api/v1/media/x/y/p.png"})
    dispatch(%*{"id": "draft.change", "value": "look at this"})
    dispatch(%*{"id": "send"})
    check sent().anyIt(
      it == "PRIVMSG #freeq :look at this " &
            "https://irc.freeq.at/api/v1/media/x/y/p.png")

  test "a picture with no words is a message too":
    dispatch(%*{"id": "attachment.ready:https://irc.freeq.at/api/v1/media/x/y/p.png"})
    dispatch(%*{"id": "send"})
    check sent().anyIt(
      it == "PRIVMSG #freeq :https://irc.freeq.at/api/v1/media/x/y/p.png")

  test "and a failure is said rather than swallowed":
    dispatch(%*{"id": "attachment.failed:Upload failed (413)"})
    check app.hasError
    check app.error == "Upload failed (413)"

suite "receiving replies":
  setup:
    reset()
    joined("#freeq")

  test "the standardized draft reply tag names its target":
    say("@msgid=m1 :alice!a@h PRIVMSG #freeq :first",
        "@+draft/reply=m1;msgid=m2 :bob!b@h PRIVMSG #freeq :answer")
    check app.rooms["#freeq"].messageById("m2").get.replyTo == "m1"

  test "the freeq reply tag remains accepted":
    say("@msgid=m1 :alice!a@h PRIVMSG #freeq :first",
        "@+reply=m1;msgid=m2 :bob!b@h PRIVMSG #freeq :answer")
    check app.rooms["#freeq"].messageById("m2").get.replyTo == "m1"

suite "unsending a line":
  setup:
    reset()
    joined("#freeq")
    dispatch(%*{"id": "room.open:#freeq"})
    say(":alice!a@h PRIVMSG #freeq :@msgid=m1 something regrettable")
    say("@msgid=m1 :alice!a@h PRIVMSG #freeq :something regrettable")
    say("@msgid=m2 :bob!b@h PRIVMSG #freeq :and one of bob's")
    discard sent()

  test "the delete goes out as a TAGMSG naming the id":
    # Not a PRIVMSG: there is no body, only the id of the line that should
    # stop existing. `+draft/delete` is freeq's tag for it and the wrong one
    # would be relayed to nobody and refused quietly.
    dispatch(%*{"id": "edit.start:m1"})
    dispatch(%*{"id": "edit.delete"})
    let out1 = sent()
    check out1.len == 1
    check "+draft/delete=m1" in out1[0]
    check " TAGMSG #freeq" in out1[0]

  test "and the line goes, without waiting for the echo":
    dispatch(%*{"id": "edit.start:m1"})
    dispatch(%*{"id": "edit.delete"})
    check app.rooms["#freeq"].messageById("m1").isNone
    check app.rooms["#freeq"].messageById("m2").isSome

  test "and edit mode is over":
    dispatch(%*{"id": "edit.start:m1"})
    check app.editing.has
    check app.draft.len > 0
    dispatch(%*{"id": "edit.delete"})
    check not app.editing.has
    check app.draft == ""

  test "somebody else's delete takes their line too":
    # The relayed TAGMSG, which is how every other client hears of this —
    # and how an op clearing up reaches us. There was no TAGMSG case at all,
    # so the line stayed on screen until a reconnect dropped it.
    say("@msgid=x :bob!b@h TAGMSG #freeq")   # no delete tag: nothing happens
    check app.rooms["#freeq"].messageById("m2").isSome
    say("@+draft/delete=m2;msgid=x :bob!b@h TAGMSG #freeq")
    check app.rooms["#freeq"].messageById("m2").isNone

  test "a delete for a line we never had is not an error":
    say("@+draft/delete=nope :bob!b@h TAGMSG #freeq")
    check not app.hasError

  test "a handoff TAGMSG gives its companion a structured task":
    # The body remains the server's ordinary readable fallback; only the
    # signed tag event makes it a task card.  This keeps a bot saying
    # "completed" from accidentally becoming a lifecycle event.
    say("@+freeq.at/act=handoff;+freeq.at/act-verb=offer;" &
        "+freeq.at/eventid=task-1;+freeq.at/act-title=ship\\sthe\\srelease;" &
        "+freeq.at/act-to=did:plc:worker;+freeq.at/act-caps=web-search " &
        ":bot!b@h TAGMSG #freeq",
        "@+freeq.at/ref=task-1;msgid=line-1 :bot!b@h PRIVMSG #freeq :offered: ship the release")
    let task = app.rooms["#freeq"].messageById("line-1").get.task
    check task.id == "task-1"
    check task.title == "ship the release"
    check task.offeredTo == "did:plc:worker"
    check task.caps == "web-search"
