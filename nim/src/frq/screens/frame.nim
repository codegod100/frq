## The tab bar, and the frame the three tabbed screens share.
##
## From `common/frq/screens/chats.cljc` and `settings.cljc`, which is where
## they live in the Clojure — pulled together here because they are one idea
## and neither screen owns them.

import std/json
import frq/[ui, cells]

func tabBar*(s: State): Node =
  hbox(%*{"spacing": 8},
    button("Chats", "screen.chats",
           if s.screen == scChats: "primary" else: "default"),
    button("Discover", "screen.discover",
           if s.screen == scDiscover: "primary" else: "default"),
    button("Settings", "screen.settings",
           if s.screen == scSettings: "primary" else: "default"))

func belowList*(s: State): int =
  ## How many points the strip under the list needs, so the scroll view knows
  ## what to reserve. A separator and a row of tabs.
  ##
  ## Counted in chrome rows rather than points in the Clojure, because a
  ## terminal's row is one cell and a window's is 34. There is no terminal any
  ## more, so this is the window's number.
  46

func tabScreen*(s: State, title0, scrollKey: string,
                body: varargs[Node]): Node =
  ## One of the three screens the tab bar moves between: the title at the top,
  ## the tabs pinned at the bottom, and the body scrolling between them.
  ##
  ## The same shape for all three, so switching tabs moves nothing but the
  ## middle. As pages they were centred columns of their own widths with the
  ## tabs wherever the content happened to end, and every switch resized the
  ## screen under the pointer.
  var list = vbox(%*{"key": "list", "fillHeight": true})
  var sc = scroll(%*{"scrollKey": scrollKey, "orientation": "vertical",
                     "reserve": belowList(s), "spacing": 8})
  for b in body:
    if not b.isNil: sc.children.add b
  list.children.add sc

  vbox(%*{"spacing": 8, "margin": 12, "fillHeight": true},
    title(title0),
    list,
    vbox(%*{"key": "foot", "spacing": 8},
      separator(),
      tabBar(s)))
