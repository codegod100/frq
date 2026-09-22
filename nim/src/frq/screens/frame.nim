## The tab bar, and the frame the three tabbed screens share.
##
## From `common/frq/screens/chats.cljc` and `settings.cljc`, which is where
## they live in the Clojure — pulled together here because they are one idea
## and neither screen owns them.

import std/json
import frq/[ui, cells]

func tabBar*(s: State): Node =
  ## The four screens, and the way between them.
  ##
  ## Lit for a conversation as well as for the list, because a conversation is
  ## what the Chats tab leads to — a bar with nothing lit on it reads as a bar
  ## that has lost its place.
  hbox(%*{"spacing": 8},
    button("Chats", "screen.chats",
           if s.screen in {scChats, scChat}: "primary" else: "default"),
    button("DMs", "screen.dms",
           if s.screen == scDms: "primary" else: "default"),
    button("Discover", "screen.discover",
           if s.screen == scDiscover: "primary" else: "default"),
    button("Settings", "screen.settings",
           if s.screen == scSettings: "primary" else: "default"))

func tabScreen*(s: State, title0, scrollKey: string,
                body: varargs[Node]): Node =
  ## One of the three screens the tab bar moves between: the title at the top,
  ## the tabs pinned at the bottom, and the body scrolling between them.
  ##
  ## The same shape for all three, so switching tabs moves nothing but the
  ## middle. As pages they were centred columns of their own widths with the
  ## tabs wherever the content happened to end, and every switch resized the
  ## screen under the pointer.
  var list = vbox(%*{"key": "list", "expand": true})
  var sc = scroll(%*{"scrollKey": scrollKey, "orientation": "vertical",
                     "spacing": 8})
  for b in body:
    if not b.isNil: sc.children.add b
  list.children.add sc

  vbox(%*{"spacing": 8, "margin": 12, "expand": true},
    title(title0),
    list,
    vbox(%*{"key": "foot", "spacing": 8},
      separator(),
      tabBar(s)))
