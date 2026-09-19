## The state record, and the few questions it answers itself.

import std/[tables, unittest]
import frq/[cells, model]

suite "initState":
  test "starts on the connect screen, not connected":
    let s = initState()
    check s.screen == scConnect
    check s.status == "Not connected"
    check not s.connecting

  test "the form is filled in with the defaults the screen shows":
    let s = initState()
    check s.formHost == defaultHost
    check s.formPort == defaultPort
    check s.formTls
    check s.formNick == "frq-guest"
    check s.authMode == amGuest

  test "at-present, because a fresh conversation is at its end":
    check initState().atPresent

  test "nothing is attached, replied to or being edited":
    let s = initState()
    check not s.attachment.has
    check not s.replyingTo.has
    check not s.editing.has
    check not s.lightbox.has

suite "wide":
  test "a phone-width window is not wide":
    var s = initState(); s.windowWidth = 420
    check not s.wide
  test "past wideWidth it is":
    var s = initState(); s.windowWidth = wideWidth
    check s.wide
  test "a window that has not reported yet is not":
    # windowWidth starts at 0, and guessing wide would put a 320pt list beside
    # a conversation on a phone.
    check not initState().wide

suite "currentRoom":
  test "the room `current` names":
    var s = initState()
    s.rooms["#test"] = initRoom("#test")
    s.current = "#test"
    check s.currentRoom.name == "#test"

  test "an empty room where nothing is current":
    # A value rather than an Option: every screen that asks is about to read
    # `.messages`, and an empty list is the honest answer for "no room".
    check initState().currentRoom.name == ""

  test "an empty room where `current` names one that is gone":
    var s = initState(); s.current = "#vanished"
    check s.currentRoom.name == ""

suite "the constants the screens share":
  test "popular channels are the discover list":
    check popularChannels.len == 6
    check popularChannels[0][0] == "#general"
