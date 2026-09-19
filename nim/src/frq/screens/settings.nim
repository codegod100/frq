## Discover and Settings — the small two.
##
## A list of rooms to join and a page of switches, transcribed from
## `common/frq/screens/settings.cljc`.

import std/[json, tables]
import ../ui, ../cells, ../model
import frame, connect

func discoverScreen*(s: State): Node =
  var body = @[dimLabel("Popular channels on freeq."), errorNote(s)]
  for (name, blurb) in popularChannels:
    let joined = s.rooms.hasKey(name) and s.rooms[name].joined
    body.add n("card", %*{"key": name}, @[
      title2(name),
      dimLabel(blurb),
      button(if joined: "Open" else: "Join",
             (if joined: "room.open:" else: "room.join:") & name)])
  tabScreen(s, "Discover", "discover-list", body)

func settingsScreen*(s: State, connected: bool, desktop: bool): Node =
  var identity = vbox(%*{"key": "identity", "spacing": 6})
  if s.formHandle.len > 0:
    identity.children.add label(s.formHandle)
    if s.brokerToken.len > 0:
      identity.children.add button("Forget Bluesky session", "session.forget",
                                   "destructive")
  else:
    identity.children.add dimLabel("Guest — not signed in.")

  # Nothing to disconnect from when there is no connection — the way back to
  # the connect screen is what is wanted then.
  var action = vbox(%*{"key": "connection-action"})
  action.children.add(
    if connected: button("Disconnect", "disconnect", "destructive")
    else: button("Back to connect", "screen.connect"))

  var about = card(
    title2("frq"),
    dimLabel("freeq client — Nim over Flutter, on Android, Linux and the web."))
  # No Quit where there is nothing to quit: closing an app is a window's idea,
  # and Android has its own way of leaving one.
  if desktop:
    about.children.add button("Quit", "quit")

  tabScreen(s, "Settings", "settings-list", [
    card(
      title2("Connection"),
      status(s.status, live = connected),
      identity,
      separator(),
      action),
    card(
      title2("Messages"),
      checkbutton("Hide join/part messages", s.hideJoinPart,
                  "join-part.toggle"),
      dimLabel("Hides other people arriving, leaving and quitting. The " &
               "people panel still follows who is here.")),
    about])
