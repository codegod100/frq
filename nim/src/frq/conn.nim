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

import std/[net, strutils]
import trace

type
  ConnConfig* = object
    host*: string
    port*: int
    tls*: bool

var
  inbound: Channel[string]
  outbound: Channel[string]
  events: Channel[string]   ## "open" | "close: reason" | "error: reason"
  thread: Thread[ConnConfig]
  running: bool

inbound.open()
outbound.open()
events.open()

proc readerBody(cfg: ConnConfig) {.thread.} =
  {.gcsafe.}:
    var sock: Socket
    try:
      trace("conn", "dialling " & cfg.host & ":" & $cfg.port &
                    (if cfg.tls: " over TLS" else: " plain"))
      sock = newSocket(buffered = true)
      if cfg.tls:
        # CVerifyPeer: this carries a nick and, once SASL is wired, a token.
        let ctx = newContext(verifyMode = CVerifyPeer)
        ctx.wrapSocket(sock)
      sock.connect(cfg.host, Port(cfg.port))
      events.send("open")
      trace("conn", "connected")

      while running:
        # Writes FIRST, and this is not a preference: the client speaks first
        # in IRC. Draining after the read deadlocked exactly once and
        # completely — CAP/NICK/USER were queued before the socket finished
        # connecting, the loop went straight into a read, and the server had
        # nothing to say because we had not registered. Both sides waited.
        #
        # It also bounds write latency by nothing instead of by the read
        # timeout, which matters for a keystroke.
        while true:
          let (ok, pending) = outbound.tryRecv()
          if not ok: break
          trace("conn.out", pending)
          sock.send(pending & "\c\L")

        var line: string
        var timedOut = false
        try:
          # A timeout rather than a second thread for the writer: it gives the
          # outbound queue a look between lines at the price of one syscall
          # every 200ms, and one thread is one thread to shut down cleanly.
          line = sock.recvLine(timeout = 200)
        except TimeoutError:
          timedOut = true
        except OSError as e:
          events.send("error: " & e.msg)
          break

        if not timedOut and line.len == 0:
          # recvLine answering empty with no timeout is the peer going away.
          events.send("close: ")
          break

        if line.len > 0:
          trace("conn.in", line)
          inbound.send(line)

    except CatchableError as e:
      trace("conn", "!! " & e.msg)
      events.send("error: " & e.msg)
    finally:
      if not sock.isNil:
        try: sock.close() except CatchableError: discard
      trace("conn", "reader done")

proc open*(cfg: ConnConfig) =
  if running: return
  # Drain anything a previous connection left, so a reconnect does not deliver
  # the last one's backlog to the new one's callbacks.
  while inbound.tryRecv()[0]: discard
  while events.tryRecv()[0]: discard
  running = true
  createThread(thread, readerBody, cfg)

proc send*(line: string) =
  if running: outbound.send(line)

proc close*() =
  if not running: return
  running = false
  joinThread(thread)
  trace("conn", "closed")

proc tryLine*(): (bool, string) = inbound.tryRecv()
proc tryEvent*(): (bool, string) = events.tryRecv()
