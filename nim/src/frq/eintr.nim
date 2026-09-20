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
  if e of OSError and ((ref OSError)(e)).errorCode.int32 == p.EINTR.int32:
    true
  else:
    # The message as well as the code, and for an OSError too: a code of zero
    # with those words in the text is a wrapper that lost the errno on the
    # way, not a different failure.
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

# ------------------------------------------------- asking for restartable calls

proc sigactionRaw(sig: cint, act, old: ptr Sigaction): cint
  {.importc: "sigaction", header: "<signal.h>".}
  ## C's own shape, because the question here is "what is installed?" and
  ## Nim's binding takes the new action where C takes a NULL. Passing an
  ## uninitialised struct there does not read the handler, it replaces it
  ## with SIG_DFL — and the first signal after that killed the process,
  ## which is how this line came to be written.

proc sigactionOf*(sig: cint, into: var Sigaction): bool =
  ## What is installed for `sig`, without changing it. Exported for the test
  ## that checks this module leaves a handler as it found it.
  sigactionRaw(sig, nil, addr into) == 0

proc restartOn(sig: cint) =
  ## Add `SA_RESTART` to whatever handler is already installed for `sig`.
  ##
  ## The handler itself is not touched — same function, same mask. The flag
  ## says only what the kernel should do to a syscall the signal lands in:
  ## restart it rather than fail it with EINTR.
  var current: Sigaction
  if sigactionRaw(sig, nil, addr current) != 0: return
  if (current.sa_flags and p.SA_RESTART) != 0: return
  var updated = current
  updated.sa_flags = current.sa_flags or p.SA_RESTART
  discard sigactionRaw(sig, addr updated, nil)

proc restartableSyscalls*() =
  ## Ask for interrupted syscalls to be restarted rather than reported.
  ##
  ## Retrying is not enough on its own, and the reason is arithmetic: the
  ## Dart VM's profiler samples every thread about a thousand times a second,
  ## and an HTTPS round trip takes far longer than a millisecond. Every
  ## attempt is interrupted, so three attempts are three failures — which is
  ## what a signal storm against a real request showed, five times out of
  ## five.
  ##
  ## So the flag, which costs nothing and changes nobody's handler. The
  ## profiler still gets its signal and still samples; the read underneath
  ## carries on rather than failing. The retries stay, for a signal arriving
  ## from somewhere this never reached.
  for sig in [p.SIGPROF, p.SIGALRM, p.SIGVTALRM, p.SIGCHLD]:
    restartOn(sig)
