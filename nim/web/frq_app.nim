## frq in a browser: the core, painted by nimkit's web backend.
##
## The same program `kit/frq_desktop.nim` is on GTK. `frq_web` is the seam a
## page's scripts reach the core through (`globalThis.frq`), and is imported
## here unchanged, so `frq_host.js` drives the socket, the sign-in and the
## uploads exactly as it did; what changed is only who draws. That used to be
## Flutter, reading the tree as JSON through `frq.render`; it is now
## `frqkit/render` reading the tree itself, in the same script.
##
##   just run web
##
## Loaded at the end of `<body>`, before `frq_host.js`: nimkit wants a body to
## put the root in, and the host wants `globalThis.frq` the moment it runs.

import std/json
import nimkit
import frq/[reducer, tree, trace]
import frq_web
import frqkit/[render, theme]

proc addStyle(css: cstring) {.importjs: """
  (() => { const s = document.createElement('style'); s.textContent = #; document.head.appendChild(s); })()""".}

const insertImagePng = staticRead("../assets/insert-image.png")

var shownGen = -1

proc paint() =
  ## The screen, if it moved — whoever moved it. `frq_host.js` dispatches
  ## through `frq.dispatch` without going through here, so the clock below
  ## notices those by the tree's generation rather than being told.
  discard refresh()
  if treeGen != shownGen:
    shownGen = treeGen
    render(treeNode)

proc dispatchNow(id, value: string) =
  try:
    dispatch(%*{"id": id, "value": value})
  except CatchableError as e:
    trace("dispatch", "!! " & e.msg)
  paint()

proc main() =
  appName = "frq"
  # Nobody reads the JSON here: Flutter did, and the renderer walks the tree.
  wantJson = false
  insertImage = insertImagePng
  sendHook = dispatchNow
  inputHook = proc (id, value: string) = input($(%*{"id": id, "value": value}))
  # Left nil: a pasted picture is the page's `paste` event, which
  # `frq_host.js` catches before the field sees it.
  onWindowSize = proc (w, h: int) =
    windowWidth = w
    dispatchNow("window.size", $w & "x" & $h)

  let content = newRoot()
  paint()
  run("frq", content)
  # After nimkit's own sheet, so frq's look wins where both speak.
  addStyle(webCss().cstring)
  discard every(50, paint)

main()
