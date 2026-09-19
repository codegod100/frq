## A signal is not a failure.
##
## `EINTR` is what a blocking syscall returns when a signal arrives while it
## is waiting: nothing has gone wrong, the call simply has to be made again.
## Nim turns it into an `OSError` reading "Interrupted system call", and
## everything here used to treat that as the connection breaking — so a
## socket read, an HTTPS round trip or a sign-in would fail with `⚠
## Interrupted system call` on the screen and a disconnect behind it.
##
## Nothing in the Nim test suite ever sees one, which is the whole problem:
## a test binary has no signals to speak of. The app is a Flutter process,
## and the Dart VM's profiler sends SIGPROF to every thread in it, ours
## included, hundreds of times a second. Whether a given signal interrupts a
## syscall or resumes it is decided by an `SA_RESTART` flag on a handler this
## code does not install and cannot see.
##
## So: retry, and keep the distinction narrow. Only EINTR is retried; every
## other error is the failure it says it is.

import std/strutils
import std/posix as p

func interrupted*(e: ref CatchableError): bool =
  ## Whether this error is only a signal having arrived.
  ##
  ## By `errorCode` where there is one, and by message otherwise: a library
  ## that catches an OSError and re-raises its text — `httpclient` does this
  ## in places — loses the code but keeps the words.
  if e of OSError:
    ((ref OSError)(e)).errorCode.int32 == p.EINTR.int32
  else:
    "Interrupted system call" in e.msg

template retrying*(attempts: int, body: untyped): untyped =
  ## Run `body`, again if a signal cut it short.
  ##
  ## A bounded count rather than a loop: if something really is raising EINTR
  ## for ever, failing is better than spinning where nobody can see it.
  var tries = 0
  while true:
    tries.inc
    try:
      body
      break
    except CatchableError as e:
      if tries < attempts and interrupted(e): continue
      raise
