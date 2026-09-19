## The connect screen.
##
## A faithful transcription of `common/frq/screens/connect.cljc` — the same
## copy, the same fields, the same three modes — so the two can be put side by
## side and any disagreement is a bug rather than an opinion.
##
## Where the Clojure derefs a cell this reads a field, and where it puts a
## closure in `:on-click` this puts an event id. That substitution is the only
## systematic difference between the two files.

import std/json
import ../ui, ../cells

const transportNote* =
  "TLS comes from dart:io, so :6697 works here; untick it for a plain :6667 listener."

func errorNote*(s: State): Node =
  ## Always a node, never nothing.
  ##
  ## A conditional child that disappears shifts every sibling after it, and a
  ## renderer matching children by position would patch the header into a card
  ## when an error appeared mid-screen. A stable wrapper with a stable key
  ## keeps the shape of the tree fixed and only its contents changing.
  result = vbox(%*{"key": "error-note", "spacing": 6})
  if s.hasError:
    result.children.add card(
      label("⚠ " & s.error),
      button("Dismiss", "error.dismiss"))

func modeTabs(s: State): Node =
  hbox(%*{"spacing": 8},
    button("Guest", "mode.guest",
           if s.authMode == amGuest: "primary" else: "default"),
    button("Bluesky", "mode.bluesky",
           if s.authMode == amBluesky: "primary" else: "default"),
    button("App password", "mode.app-password",
           if s.authMode == amAppPassword: "primary" else: "default"))

func serverFields(s: State): Node =
  ## Every entry carries a key. A renderer that keeps a text controller per
  ## field needs a stable name for it, and without one the host and the port
  ## shared a controller and both showed the port.
  vbox(%*{"spacing": 6},
    label("Server"),
    hbox(%*{"spacing": 8},
      entry("host", s.formHost, "host", "host.change", width = 220),
      entry("port", s.formPort, "6697", "port.change", width = 90)),
    checkbutton("TLS", s.formTls, "tls.toggle"))

func authFields(s: State): Node =
  case s.authMode
  of amBluesky:
    result = vbox(%*{"spacing": 6},
      title2("Sign in with Bluesky"),
      dimLabel("Opens your browser for AT Protocol OAuth. freeq's broker " &
               "hands back a token; no password passes through frq."),
      label("Handle"),
      entry("handle", s.formHandle, "alice.bsky.social", "handle.change",
            width = 320))
    # Both of these are stable wrappers for the reason `errorNote` is one.
    var remembered = vbox(%*{"key": "remembered", "spacing": 4})
    if s.brokerToken.len > 0:
      remembered.children.add vbox(%*{"spacing": 4},
        dimLabel("Session remembered — Connect will not need the browser."),
        button("Forget saved session", "session.forget"))
    result.children.add remembered

    var login = vbox(%*{"key": "login-url", "spacing": 4})
    if s.loginUrl.len > 0:
      login.children.add vbox(%*{"spacing": 4},
        dimLabel("If the browser did not open, visit:"),
        label(s.loginUrl))
    result.children.add login

  of amAppPassword:
    result = vbox(%*{"spacing": 6},
      title2("Sign in with an app password"),
      dimLabel("No browser. Your app password goes to your own PDS; freeq " &
               "is handed the session it mints."),
      label("Handle"),
      entry("handle", s.formHandle, "alice.bsky.social", "handle.change",
            width = 320),
      label("App password"),
      entry("app-password", s.formAppPassword, "xxxx-xxxx-xxxx-xxxx",
            "app-password.change", width = 320),
      dimLabel("Make one at bsky.app → Settings → App Passwords."))

  of amGuest:
    result = vbox(%*{"spacing": 6},
      title2("Connect as guest"),
      label("Nick"),
      entry("nick", s.formNick, "your nick", "nick.change", width = 320))

func connectAction(s: State): Node =
  if s.connecting:
    # Cancel beside the spinner. A connection that never completes — a host
    # that does not answer, a TLS handshake that hangs — is otherwise a
    # spinner with no way out but killing the window.
    hbox(%*{"spacing": 8},
      spinner(),
      dimLabel(s.status),
      button("Cancel", "cancel"))
  else:
    hbox(%*{"spacing": 8},
      button("Connect", "connect", "primary"),
      dimLabel(s.status))

func connectScreen*(s: State): Node =
  page(%*{"maxWidth": 520},
    title("frq"),
    dimLabel("freeq client — guest, or your Bluesky identity."),
    errorNote(s),
    card(
      modeTabs(s),
      authFields(s),
      serverFields(s),
      separator(),
      connectAction(s)),
    dimLabel(transportNote))
