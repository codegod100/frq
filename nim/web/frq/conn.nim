## The transport, in a browser.
##
## The same three operations `frq/conn` has on a desktop — connect, send,
## close — and the same two queues the reducer drains. What is different is
## who owns the socket: there, two threads and an OpenSSL connection to
## :6697; here, a WebSocket in JavaScript, because a browser cannot open a
## TCP socket and does not need to. freeq publishes `wss://irc.freeq.at/irc`
## for exactly this, SASL and all.
##
## So nothing here dials anything. The host calls `feed` with each line that
## arrives and `event` when the socket opens or closes, and takes what this
## queues with `tryOutbound`. Those two are not new: they were added so the
## reducer's answer to a line could be tested without a socket, and a browser
## is the same problem — something else owns the I/O.

import std/deques

type ConnConfig* = object
  host*: string
  port*: int
  tls*: bool

var
  inbound: Deque[string]
  outbound: Deque[string]
  events: Deque[string]
  running: bool
  want: ConnConfig
    ## What the host should connect to, once it asks.

proc open*(cfg: ConnConfig) =
  ## Not a connection: a request for one. The host reads `wanted` and opens
  ## the WebSocket itself, then says `open` through `event`.
  inbound.clear()
  events.clear()
  outbound.clear()
  want = cfg
  running = true

proc wanted*(): ConnConfig = want
  ## Where the host is being asked to connect. A desktop would have dialled
  ## by now; a browser is being told what to dial.

proc send*(line: string) = outbound.addLast(line)
proc tryOutbound*(): (bool, string) =
  if outbound.len == 0: (false, "") else: (true, outbound.popFirst())

proc feed*(line: string) = inbound.addLast(line)
proc event*(e: string) = events.addLast(e)

proc close*() =
  running = false
  events.addLast("close: ")

proc tryLine*(): (bool, string) =
  if inbound.len == 0: (false, "") else: (true, inbound.popFirst())

proc tryEvent*(): (bool, string) =
  if events.len == 0: (false, "") else: (true, events.popFirst())

proc isRunning*(): bool = running
