## Tracing, on when `FRQ_TRACE` is set.
##
## The same switch the rest of frq uses — README.md documents `FRQ_TRACE=1`
## for the IRC lines — because a second convention for a second language is a
## thing to remember rather than a thing to use.
##
## To stderr and not stdout: stdout is a bundle's own, and a Flutter app on
## Linux prints to the terminal it was launched from. `just nim-app run`
## shows these inline.
##
## Cheap when off. The check is a `let` read once at load rather than a getEnv
## per call, and every `trace` call site guards on it before doing any of the
## string building — which matters because the argument to a trace call is
## usually the expensive part.

import std/[os, strutils, times]

let enabled* = getEnv("FRQ_TRACE").len > 0 and getEnv("FRQ_TRACE") != "0"

proc trace*(topic: string, msg: string) =
  ## One line: a timestamp, a topic, and the message.
  if not enabled: return
  let t = now().format("HH:mm:ss'.'fff")
  stderr.writeLine("[frq " & t & "] " & topic.alignLeft(9) & " " & msg)
  # Flushed every line rather than at exit: a trace lost when the process dies
  # is worth nothing, and the process dying is the case most worth tracing.
  stderr.flushFile()

template traced*(topic: string, body: untyped) =
  ## For a message that costs something to build. The body is not evaluated
  ## at all when tracing is off.
  if enabled:
    trace(topic, body)
