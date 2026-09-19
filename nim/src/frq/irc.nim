## The IRC connection: a socket on its own thread, and two queues.
##
## The threading model is the whole design, and it is chosen to avoid a
## problem rather than to be clever. Nim's ORC is thread-local for ref types,
## so sharing the `State` record between a reader thread and the UI thread
## would mean a lock around every field and a heap two threads both collect.
## Instead **nothing is shared**: the socket thread owns the socket and speaks
## only in channels, and the state stays where it always was, on whichever
## thread called in from Dart.
##
##   reader thread  ──lines──▶  inbound  ──▶  drain() on the UI thread
##   UI thread      ──lines──▶  outbound ──▶  writer, on the socket thread
##
## `drain` is called from `frq_ui_render`, so the tree Dart gets is always
## built after every line that had arrived when it asked. Dart polls; there is
## no callback into Dart and deliberately so — a Dart callback invoked from a
## foreign thread has to be marshalled onto the main isolate, which is a whole
## mechanism (`NativeCallable`, ports) for something a 100ms timer does for
## free at this size.

import std/[net, strutils]
import trace

type
  ConnConfig* = object
    host*: string
    port*: int
    tls*: bool
    nick*: string

  Status* = enum
    stIdle, stConnecting, stRegistered, stFailed, stClosed

var
  inbound: Channel[string]    ## raw lines from the server
  outbound: Channel[string]   ## raw lines to the server
  statusChan: Channel[string] ## "connecting"/"registered"/"failed: …"/"closed"
  thread: Thread[ConnConfig]
  running: bool

inbound.open()
outbound.open()
statusChan.open()

proc send*(line: string) =
  ## Queue a line for the server. Safe from the UI thread.
  trace("irc.out", line)
  outbound.send(line)

proc tryRecvLine*(): (bool, string) = inbound.tryRecv()
proc tryRecvStatus*(): (bool, string) = statusChan.tryRecv()

proc readerBody(cfg: ConnConfig) {.thread.} =
  ## The socket, end to end. Every failure answers with a status rather than
  ## an exception: this thread has nobody to throw to.
  {.gcsafe.}:
    var sock: Socket
    try:
      statusChan.send("connecting")
      trace("irc", "dialling " & cfg.host & ":" & $cfg.port &
                   (if cfg.tls: " over TLS" else: " plain"))
      sock = newSocket(buffered = true)
      if cfg.tls:
        # CVerifyPeer, not CVerifyNone: this carries a nick and, later, a
        # token. Nim loads libssl by soname at run time, so a bundle that
        # cannot find one fails here rather than at build.
        let ctx = newContext(verifyMode = CVerifyPeer)
        ctx.wrapSocket(sock)
      sock.connect(cfg.host, Port(cfg.port))
      trace("irc", "connected")

      # Registration. No CAP and no SASL in the spike — a guest connect is
      # NICK and USER, which is the whole of what freeq needs to let one in.
      sock.send("NICK " & cfg.nick & "\c\L")
      sock.send("USER " & cfg.nick & " 0 * :" & cfg.nick & "\c\L")
      trace("irc.out", "NICK/USER as " & cfg.nick)

      # Non-blocking-ish loop: recvLine with a timeout so the outbound queue
      # gets a look in between lines. A dedicated writer thread would avoid
      # the timeout, at the price of a second thread to shut down cleanly.
      while running:
        var line: string
        var timedOut = false
        try:
          line = sock.recvLine(timeout = 200)
        except TimeoutError:
          timedOut = true
        except OSError as e:
          statusChan.send("failed: " & e.msg)
          break

        if line == "" and not timedOut:
          # recvLine answering with an empty string and no timeout is the
          # server having gone away. A timeout answers the same way, which is
          # why the two are told apart by the flag rather than by the string.
          statusChan.send("closed")
          break

        if line.len > 0:
          trace("irc.in", line)
          # PING is answered here rather than in the reducer: it is the
          # transport's own housekeeping and the screen has no opinion on it.
          if line.startsWith("PING"):
            let token = if ' ' in line: line[line.find(' ') + 1 .. ^1] else: ""
            sock.send("PONG " & token & "\c\L")
            trace("irc.out", "PONG " & token)
          else:
            inbound.send(line)

        while true:
          let (ok, pending) = outbound.tryRecv()
          if not ok: break
          sock.send(pending & "\c\L")

    except CatchableError as e:
      trace("irc", "!! " & e.msg)
      statusChan.send("failed: " & e.msg)
    finally:
      if not sock.isNil:
        try: sock.close() except CatchableError: discard
      trace("irc", "reader thread done")

proc startReal(cfg: ConnConfig) {.nimcall, gcsafe.} =
  if running: return
  running = true
  {.cast(gcsafe).}:
    createThread(thread, readerBody, cfg)

var connector*: proc(cfg: ConnConfig) {.nimcall, gcsafe.} = startReal
  ## How a connection gets opened, as a variable so a test can replace it.
  ##
  ## Without this the reducer's tests open real sockets to irc.freeq.at —
  ## which they did, and which is why this exists: a unit test for "Connect
  ## sets connecting" should not need a network, a DNS server or a running
  ## freeq. `tests/tui.nim` swaps in a stub that records the config instead.

proc goOffline*() =
  ## Replace the dialler with one that records and does nothing.
  ##
  ## For the widget tests, which build the real screens and tap the real
  ## Connect button — and which, without this, opened a TLS connection to
  ## irc.freeq.at from a unit-test runner. A test suite that needs a network
  ## is a test suite that fails on a train.
  connector = proc(cfg: ConnConfig) {.nimcall, gcsafe.} =
    trace("irc", "offline: would have dialled " & cfg.host & ":" & $cfg.port)

proc start*(cfg: ConnConfig) =
  ## Open a connection. A second call while one is running is ignored.
  trace("irc", "start " & cfg.host & ":" & $cfg.port)
  connector(cfg)

proc stop*() =
  if not running: return
  running = false
  # Up to the recvLine timeout plus a moment; joining rather than detaching so
  # the socket is shut before anything tries to open another.
  joinThread(thread)
  trace("irc", "stopped")
