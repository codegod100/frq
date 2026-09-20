## Telling a signal apart from a failure.
##
## Nothing in this suite raises a real EINTR — a test binary has no signals
## worth the name, which is exactly why the app hit this and the tests never
## did. So the errors here are built by hand, and what is checked is the
## judgement: which ones are retried, which are not, and that a retry gives up
## rather than spinning.

import std/[os, unittest]
import std/posix as p
import frq/eintr

proc osError(code: cint, msg: string): ref OSError =
  result = newException(OSError, msg)
  result.errorCode = code.int32

suite "interrupted":
  test "an OSError carrying EINTR is only a signal":
    check interrupted(osError(p.EINTR, "Interrupted system call"))
  test "any other OSError is a real failure":
    check not interrupted(osError(p.ECONNRESET, "Connection reset by peer"))
    check not interrupted(osError(p.EPIPE, "Broken pipe"))
  test "and so is an error that is not an OSError at all":
    check not interrupted(newException(ValueError, "nonsense"))
  test "but the words count where the code was lost":
    # `httpclient` catches an OSError in places and re-raises its text, which
    # keeps the message and drops the code.
    check interrupted(newException(IOError, "Interrupted system call"))

suite "retrying":
  test "a body that works runs once":
    var runs = 0
    retrying 3:
      runs.inc
    check runs == 1

  test "one cut short by a signal is run again":
    var runs = 0
    retrying 3:
      runs.inc
      if runs < 3: raise osError(p.EINTR, "Interrupted system call")
    check runs == 3

  test "a real failure is raised at once, not retried":
    var runs = 0
    expect OSError:
      retrying 5:
        runs.inc
        raise osError(p.ECONNREFUSED, "Connection refused")
    check runs == 1

  test "and a signal that never stops gives up rather than spinning":
    var runs = 0
    expect OSError:
      retrying 4:
        runs.inc
        raise osError(p.EINTR, "Interrupted system call")
    check runs == 4

suite "restartableSyscalls":
  test "adds SA_RESTART without disturbing the handler":
    # The flag says what the kernel does to an interrupted syscall. It must
    # not change which function runs, or whose signal it is — the profiler
    # whose handler this finds is somebody else's.
    proc handler(sig: cint) {.noconv.} = discard
    var wanted: Sigaction
    discard sigemptyset(wanted.sa_mask)
    wanted.sa_handler = handler
    wanted.sa_flags = 0
    check p.sigaction(SIGALRM, wanted, nil) == 0

    restartableSyscalls()

    var got: Sigaction
    check sigactionOf(SIGALRM, got)
    check (got.sa_flags and p.SA_RESTART) != 0
    check got.sa_handler == handler

  test "and leaves one that already has it alone":
    proc handler(sig: cint) {.noconv.} = discard
    var wanted: Sigaction
    discard sigemptyset(wanted.sa_mask)
    wanted.sa_handler = handler
    wanted.sa_flags = p.SA_RESTART
    check p.sigaction(SIGALRM, wanted, nil) == 0
    restartableSyscalls()
    var got: Sigaction
    check sigactionOf(SIGALRM, got)
    check got.sa_handler == handler
    check (got.sa_flags and p.SA_RESTART) != 0
