## The connect screen, as a pure function of the state.
##
## Transcribed from `common/frq/screens/connect.cljc` rather than redesigned,
## so that the two can be put side by side and disagreements are bugs rather
## than opinions. Where the Clojure derefs a cell this reads a field; where it
## puts a closure in `:on-click` this puts an event id.
##
## Nothing here mutates. That is not a style rule, it is what makes the
## boundary cheap: the renderer can be called at any time, twice, or not at
## all, and the only thing that changes the screen is `dispatch`.

import std/json
import ../ui, ../state

func errorNote(s: State): Node =
  ## A stable wrapper with a stable key, kept from the original for the
  ## original's reason: a renderer matching children by position would patch
  ## the header into a card when an error appeared mid-screen. The wrapper
  ## keeps the tree's shape fixed and only its contents changing.
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
  vbox(%*{"spacing": 6},
    label("Server"),
    hbox(%*{"spacing": 8},
      entry("host", s.formHost, "host", "host.change", width = 220),
      entry("port", s.formPort, "6697", "port.change", width = 90)),
    checkbutton("TLS", s.formTls, "tls.toggle"))

func connectAction(s: State): Node =
  if s.connecting:
    # Cancel, and not just a spinner. Without it a connection that never
    # completes — a host that does not answer, a TLS handshake that hangs — is
    # a spinner with no way out but killing the window, which is exactly what
    # the first run of this spike did.
    hbox(%*{"spacing": 8},
      spinner(),
      dimLabel(s.status),
      button("Cancel", "cancel"))
  else:
    hbox(%*{"spacing": 8},
      button("Connect", "connect", "primary"),
      dimLabel(s.status))

func authFields(s: State): Node =
  case s.authMode
  of amGuest:
    vbox(%*{"spacing": 6},
      label("Nickname"),
      entry("nick", s.formNick, "frq-guest", "nick.change", width = 220))
  of amBluesky:
    vbox(%*{"spacing": 6},
      title2("Sign in with Bluesky"),
      dimLabel("Opens your browser for AT Protocol OAuth. freeq's broker " &
               "hands back a token; no password passes through frq."),
      label("Handle"),
      entry("handle", s.formHandle, "alice.bsky.social", "handle.change",
            width = 320),
      vbox(%*{"key": "remembered", "spacing": 4},
        if s.brokerToken.len > 0:
          dimLabel("Session remembered — Connect will not need the browser.")
        else: nil))
  of amAppPassword:
    vbox(%*{"spacing": 6},
      title2("Sign in with an app password"),
      dimLabel("Goes to your own PDS and nowhere else. Never written to disk."),
      label("Handle"),
      entry("handle", s.formHandle, "alice.bsky.social", "handle.change",
            width = 320),
      label("App password"),
      entry("app-password", s.formAppPassword, "xxxx-xxxx-xxxx-xxxx",
            "app-password.change", width = 320))

func connectScreen*(s: State): Node =
  page(%*{"maxWidth": 520},
    title("frq"),
    dimLabel("freeq client — guest, or your Bluesky identity."),
    errorNote(s),
    card(
      modeTabs(s),
      authFields(s),
      serverFields(s),
      connectAction(s)))
