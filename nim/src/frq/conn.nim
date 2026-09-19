## A transport, and nothing above it.
##
## This is `frq.net`'s three operations — connect, send, close — with a socket
## and a TLS context behind them. It knows about lines; it does not know about
## IRC, about a state machine, or about a screen.
##
## That boundary is the whole point of this module existing separately from
## `irc.nim`. The spike had Nim owning the state and the screens, which meant
## reimplementing screens that already exist and are far better — 1,518 lines
## of chat with reactions, replies and images, against forty lines of
## facsimile. Wiring Nim in *under* `frq.net` instead leaves every screen, the
## cells they read and the actions they call exactly where they are, and
## replaces only the part that was always platform code.
##
## Threading as before: the socket thread shares nothing, and speaks in
## channels. See irc.nim's comment for why ORC makes that the sane choice.

import std/net
import std/posix as p   ## for `shutdown(2)`; see `close`
import frq/[trace, eintr]

type
  ConnConfig* = object
    host*: string
    port*: int
    tls*: bool

var
  inbound: Channel[string]
  outbound: Channel[string]
  events: Channel[string]   ## "open" | "close: reason" | "error: reason"
  reader: Thread[ConnConfig]
  writer: Thread[int]
  running: bool
  shared: Socket
    ## The socket both threads use. One reader and one writer on the same
    ## OpenSSL connection is supported and is what every IRC client does; what
    ## is NOT supported is two of either, which is why there are exactly two
    ## threads and neither of them is the caller's.

# Opened once, at module init. If you ever see this run twice, something is
# calling NimMain after the library constructor already has — see `frq_init`,
# which is empty for exactly that reason.
inbound.open()
outbound.open()
events.open()


proc writerBody(unused: int) {.thread.} =
  ## Blocks on the queue, not on the socket.
  ##
  ## A thread of its own because the alternative does not work: a single
  ## thread has to both wait for the server and notice what the client wants
  ## to say, and on a TLS socket there is no reliable way to wait for one with
  ## a bound on the other. `recvLine(timeout)` and `recv(timeout)` both block
  ## in SSL_read past their timeout — select fires on a TLS *record*, which
  ## need not hold a complete line — so registration deadlocked: CAP/NICK/USER
  ## sat in the queue while the reader waited for a server that had nothing to
  ## say until we sent them.
  {.gcsafe.}:
    while true:
      let line = outbound.recv()      # blocks until there is one
      if not running: break
      if shared.isNil: continue
      try:
        trace("conn.out", line)
        retrying 5:
          shared.send(line & "\c\L")
      except CatchableError as e:
        events.send("error: " & e.msg)
        break

proc readerBody(cfg: ConnConfig) {.thread.} =
  {.gcsafe.}:
    try:
      trace("conn", "dialling " & cfg.host & ":" & $cfg.port &
                    (if cfg.tls: " over TLS" else: " plain"))
      var sock = newSocket(buffered = true)
      if cfg.tls:
        # CVerifyPeer: this carries a nick and, once SASL is wired, a token.
        let ctx = newContext(verifyMode = CVerifyPeer)
        ctx.wrapSocket(sock)
      sock.connect(cfg.host, Port(cfg.port))
      shared = sock
      createThread(writer, writerBody, 0)
      events.send("open")
      trace("conn", "connected")

      while running:
        var line: string
        try:
          line = sock.recvLine()
        except CatchableError as e:
          # A signal arriving while we waited is not the server going away.
          # The Dart VM profiles every thread in the process, this one
          # included, so a read that is interrupted and then reported as a
          # broken connection is a disconnect several times a minute.
          if interrupted(e) and running: continue
          if running: events.send("error: " & e.msg)
          break
        if line.len == 0:
          if running: events.send("close: ")
          break
        trace("conn.in", line)
        inbound.send(line)

    except CatchableError as e:
      trace("conn", "!! " & e.msg)
      events.send("error: " & e.msg)
    finally:
      running = false
      # Unblock the writer, which is sitting in `outbound.recv()`.
      outbound.send("")
      if not shared.isNil:
        try: shared.close() except CatchableError: discard
        shared = nil
      trace("conn", "reader done")

proc open*(cfg: ConnConfig) =
  if running: return
  # Drain anything a previous connection left, so a reconnect does not deliver
  # the last one's backlog to the new one's callbacks.
  while inbound.tryRecv()[0]: discard
  while events.tryRecv()[0]: discard
  # Including anything written while there was nowhere to write it: a line
  # queued before this connection existed was meant for the last one.
  while outbound.tryRecv()[0]: discard
  running = true
  createThread(reader, readerBody, cfg)

proc send*(line: string) =
  ## Queued whether or not there is a connection.
  ##
  ## It used to drop the line when there was none, which made the whole of
  ## what this client says to a server unobservable from a test — nothing
  ## could ask "and what did it send?" without opening a socket. `open` drains
  ## the queue, so a line written while disconnected is never delivered to the
  ## next connection; it is simply readable in between.
  outbound.send(line)

proc tryOutbound*(): (bool, string) = outbound.tryRecv()
  ## What is queued to go out, for a test that has no socket. The writer
  ## thread takes these when there is one.

proc feed*(line: string) =
  ## Put a line in as though the server had sent it.
  ##
  ## The other half of `tryOutbound`, and the reason both exist: the reducer's
  ## answer to an incoming line was the largest untested thing in this program
  ## — reachable only through a real socket — and that is where a missing
  ## CHATHISTORY request sat unnoticed through the whole port. Together they
  ## make the conversation checkable from both ends without one.
  inbound.send(line)

proc close*() =
  if not running: return
  running = false
  # The reader is blocked in recvLine, and waking it is this thread's job —
  # but closing the socket is NOT. `Socket.close()` on a TLS socket calls
  # SSL_shutdown and SSL_free, and the reader is inside SSL_read on that very
  # handle: freeing it here is a use-after-free in `uniRecv`, which arrives as
  # `SIGSEGV: Illegal storage access. (Attempt to read from nil?)` and takes
  # the whole app with it. Every disconnect had a chance of it.
  #
  # `shutdown(2)` on the descriptor instead. It frees nothing and owns
  # nothing; it makes the blocked read return, and the reader then closes the
  # socket in its own `finally` — the one thread that may.
  if not shared.isNil:
    discard p.shutdown(shared.getFd(), SHUT_RDWR)
  outbound.send("")
  joinThread(reader)
  trace("conn", "closed")

proc tryLine*(): (bool, string) = inbound.tryRecv()
proc tryEvent*(): (bool, string) = events.tryRecv()
