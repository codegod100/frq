## frq on the Linux desktop: the core, painted by nimkit's GTK backend.
##
## One process and one language. The core owns the state, the screens, the
## IRC connection and the signing exactly as it did under Flutter; what was
## Dart is now `frqkit/render` walking the core's tree into GTK widgets, and
## this file, which is the host — the window, the clock that polls the core,
## and the three things only a desktop can do for it: open a file dialog,
## look at the clipboard, and post a picture.
##
##   just run desktop
##
##   FRQ_AUTOCONNECT=1  press Connect at startup; FRQ_NICK overrides the nick
##   FRQ_DEMO=1         open on a representative room instead, no server
##   FRQ_THEME=light    or dark; otherwise whatever the desktop's theme is

import std/[json, os, osproc, strutils, times]
import nimkit
import nimkit/backend/gtkapi
import frq/[eintr, reducer, tree, trace]
import frq_core
import frqkit/[render, theme]

const insertImagePng = staticRead("../assets/insert-image.png")

# ------------------------------------------------------------------ the core

var shownGen = -1

proc paint() =
  ## The screen, if it moved. `refresh` drains the socket first, so this is
  ## also how lines that arrived get onto the screen.
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

# ------------------------------------------------------------ the platform

proc clipboardTypes(): (string, seq[string]) =
  ## The picture type on the clipboard and the command that reads it, or ""
  ## where there is none. `wl-paste` on Wayland and `xclip` on X, whichever
  ## answers; a desktop with neither has no picture to find.
  const kinds = ["image/png", "image/jpeg", "image/gif", "image/webp"]
  let tools = [
    (@["wl-paste", "--list-types"], @["wl-paste", "--no-newline", "--type"]),
    (@["xclip", "-selection", "clipboard", "-t", "TARGETS", "-o"],
     @["xclip", "-selection", "clipboard", "-o", "-t"])]
  for (list, read) in tools:
    if findExe(list[0]).len == 0: continue
    let (output, code) =
      try: execCmdEx(quoteShellCommand(list), options = {poUsePath})
      except CatchableError: ("", 1)
    if code != 0: continue
    for k in kinds:
      for line in output.splitLines:
        if line.strip == k: return (k, read & @[k])
    return ("", @[])
  ("", @[])

proc clipboardPicture(): (string, string) =
  ## The picture on the clipboard as (bytes, type), or empty.
  let (kind, cmd) = clipboardTypes()
  if kind.len == 0: return
  let (bytes, code) =
    try: execCmdEx(quoteShellCommand(cmd), options = {poUsePath})
    except CatchableError: ("", 1)
  if code == 0 and bytes.len > 0: (bytes, kind) else: ("", "")

proc mimeFor(path: string): string =
  let lower = path.toLowerAscii
  if lower.endsWith(".jpg") or lower.endsWith(".jpeg"): "image/jpeg"
  elif lower.endsWith(".gif"): "image/gif"
  elif lower.endsWith(".webp"): "image/webp"
  else: "image/png"

proc upload(host, did, channel, bytes, name, mime: string) =
  ## A picture to freeq's media endpoint, as the multipart form it wants; the
  ## URL that comes back goes in the line, which is how a picture travels on
  ## IRC.
  if bytes.len > 10 * 1024 * 1024:
    dispatchNow("attachment.failed:That picture is over the 10MB the server takes.", "")
    return
  let boundary = "----frq" & $bytes.len & "x" & $epochTime().int64
  var body = "--" & boundary & "\r\nContent-Disposition: form-data; name=\"did\"\r\n\r\n" & did & "\r\n"
  if channel.len > 0:
    body.add "--" & boundary & "\r\nContent-Disposition: form-data; name=\"channel\"\r\n\r\n" &
             channel & "\r\n"
  body.add "--" & boundary & "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"" &
           name & "\"\r\nContent-Type: " & mime & "\r\n\r\n" & bytes & "\r\n--" & boundary & "--\r\n"
  request("POST", "https://" & host & "/api/v1/upload", proc (r: Response) =
    if r.status div 100 != 2:
      dispatchNow("attachment.failed:" &
        (if r.status == 0: r.error else: "Upload failed (" & $r.status & ")"), "")
      return
    let url = try: parseJson(r.body){"url"}.getStr() except CatchableError: ""
    if url.len == 0:
      dispatchNow("attachment.failed:The server took the picture but named no URL for it.", "")
    else:
      dispatchNow("attachment.ready:" & url, ""),
    headers = @[("Content-Type", "multipart/form-data; boundary=" & boundary)], body = body)

proc pickPicture(want: string) =
  ## A picture the core asked for: chosen, read, and posted. The core knows
  ## who is asking and where to, and nothing else about it.
  let j = try: parseJson(want) except CatchableError: return
  let host = j{"host"}.getStr()
  let did = j{"did"}.getStr()
  let channel = j{"channel"}.getStr()
  if j{"source"}.getStr() == "clipboard":
    let (bytes, mime) = clipboardPicture()
    # Gone between the keypress and now: somebody copied something else.
    if bytes.len == 0:
      dispatchNow("attachment.failed", "")
      return
    upload(host, did, channel, bytes, "pasted." & mime.split('/')[1], mime)
    return
  chooseFile("Attach a picture", proc (path: string) =
    # An empty path is the reader closing the dialog, which is not a failure
    # and is not reported as one.
    if path.len == 0:
      dispatchNow("attachment.failed", "")
      return
    let bytes = try: readFile(path) except CatchableError: ""
    if bytes.len == 0:
      dispatchNow("attachment.failed:Could not read " & path.extractFilename, "")
      return
    upload(host, did, channel, bytes, path.extractFilename, mimeFor(path)),
    patterns = @["*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp"], filterName = "Pictures")

# ------------------------------------------------------------------ the look

{.push cdecl, importc.}
proc gtk_settings_get_default(): pointer
proc g_object_get(o: pointer, first: cstring): void {.varargs.}
{.pop.}

proc prefersDark(): bool =
  ## Whether the desktop is dark: the theme's name says so on KDE and most
  ## others (Breeze-Dark, Adwaita-dark), the preference flag on GNOME.
  let forced = getEnv("FRQ_THEME").toLowerAscii
  if forced == "dark": return true
  if forced == "light": return false
  var name: cstring
  var dark: cint
  let s = gtk_settings_get_default()
  if s == nil: return true
  g_object_get(s, "gtk-theme-name", addr name, "gtk-application-prefer-dark-theme", addr dark, nil)
  let theme = if name == nil: "" else: $name
  dark != 0 or "dark" in theme.toLowerAscii or getEnv("GTK_THEME").toLowerAscii.contains("dark")

proc applyTheme() =
  let css = gtkCss(if prefersDark(): frqDark else: frqLight)
  let p = gtk_css_provider_new()
  discard gtk_css_provider_load_from_data(p, css.cstring, css.len, nil)
  # Above the application priority nimkit's own sheet takes, so frq's
  # colours win where both speak.
  gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), p,
                                            GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1)

# ------------------------------------------------------------------- start

proc main() =
  appName = "frq"
  # Before anything opens a socket; see `frq_init`.
  restartableSyscalls()
  reducer.restore()
  wantJson = false
  insertImage = insertImagePng
  sendHook = dispatchNow
  inputHook = proc (id, value: string) = input($(%*{"id": id, "value": value}))
  clipboardHasPicture = proc (): bool = clipboardTypes()[0].len > 0
  onWindowSize = proc (w, h: int) =
    windowWidth = w
    dispatchNow("window.size", $w & "x" & $h)
  applyTheme()

  if getEnv("FRQ_DEMO") notin ["", "0"]:
    frq_ui_demo()
  else:
    let want = getEnv("FRQ_AUTOCONNECT")
    if want notin ["", "0"]:
      let nick = getEnv("FRQ_NICK")
      if nick.len > 0: dispatchNow("nick.change", nick)
      dispatchNow("connect", "")

  let content = newRoot()
  paint()
  # A remembered sign-in connects by itself once the window is up: on the
  # desktop it is a round trip to the broker, and the window should not wait
  # on it to appear. The core decides whether there is anything to connect as.
  discard after(0, proc () = dispatchNow("auto-connect", ""))
  # Polling, because the socket lives on its own threads and nothing calls
  # into this one when a line arrives.
  discard every(100, proc () =
    paint()
    let want = wantedPicture()
    if want.len > 0: pickPicture(want))
  run("frq", content, 1100, 760)

main()
