(ns frq.screens.settings
  "Discover and Settings, and the frame the tab bar sits in.

  The small two, and the last of frq.app's screens to move but the least
  interesting: a list of rooms to join and a page of switches. `tab-screen`
  comes with them because it is what puts a tab bar under a screen, and all
  three of them are one."
  (:require [clojure.string :as str]
            [frq.actions :as actions]
            [frq.cells :as cells]
            [frq.screens.chats :refer [below-list tab-bar]]
            [frq.screens.connect :refer [error-note]]))

(defn- tab-screen
  "One of the three screens the tab bar moves between, in the chats screen's
  shape: the title at the top, the tabs pinned at the bottom, and `body`
  scrolling between them.

  The same shape for all three, so switching tabs moves nothing but the
  middle. As pages they were centred columns of their own widths with the tabs
  wherever the content happened to end, and every switch resized the screen
  under the pointer."
  [title scroll-key & body]
  [:vbox {:spacing 8 :margin 12 :fill-height true}
   [:title {:label title}]
   [:vbox {:key :list :fill-height true}
    (into [:scroll {:scroll-key scroll-key :orientation :vertical
                    :reserve (below-list) :spacing 8}]
          body)]
   [:vbox {:key :foot :spacing 8}
    [:separator {}]
    [tab-bar]]])

(defn discover-screen []
  (tab-screen "Discover" "discover-list"
   [:dim-label {:label "Popular channels on freeq."}]
   [error-note]
   (for [[name blurb] cells/popular-channels]
     (let [joined? (get-in @cells/channels [name :joined?])]
       [:card {:key name}
        [:title-2 {:label name}]
        [:dim-label {:label blurb}]
        ;; Standard, like the other Join: an action, not a state. `Open` is
        ;; the same button with the other word on it and is no more stateful.
        [:button {:label (if joined? "Open" "Join")
                  :on-click #(if joined? (actions/open-channel! name) (actions/join! name))}]]))))

(defn settings-screen []
  (tab-screen "Settings" "settings-list"
   [:card {}
    [:title-2 {:label "Connection"}]
    [:status {:label @cells/status :live (actions/connected?)}]
    [:label {:label (str "Server: " @cells/form-host ":" @cells/form-port)}]
    [:label {:label (str "Nick: " @cells/form-nick)}]
    (if-let [sess @cells/session]
      [:vbox {:spacing 2}
       [:label {:label (str "Signed in as " (:handle sess))}]
       [:dim-label {:label (or (:did sess) "")}]
       [:vbox {:key :forget}
        (when @cells/broker-token
          [:button {:label "Forget Bluesky session"
                    :kind :destructive
                    :on-click actions/forget-session!}])]]
      [:dim-label {:label "Guest — not signed in."}])
    [:separator {}]
    ;; Nothing to disconnect from when there is no connection — the way back to
    ;; the connect screen is what is wanted then.
    [:vbox {:key :connection-action}
     (if (actions/connected?)
       [:button {:label "Disconnect" :kind :destructive :on-click actions/disconnect!}]
       [:button {:label "Back to connect"
                 :on-click #(reset! cells/screen :connect)}])]]
   [:card {}
    [:title-2 {:label "Messages"}]
    [:checkbutton {:label "Hide join/part messages"
                   :active @cells/hide-join-part?
                   :on-toggled actions/toggle-hide-join-part!}]
    [:dim-label {:label "Hides other people arriving, leaving and quitting. The people panel still follows who is here."}]]
   [:card {}
    [:title-2 {:label "frq"}]
    ;; What this is. It used to be a different sentence per frontend, back
    ;; when there was more than one; there is Flutter now, on three targets.
    [:dim-label {:label "freeq client — ClojureDart over Flutter, on Android, Linux and the web."}]
    ;; No Quit where there is nothing to quit: closing an app is a window's
    ;; idea, and Android has its own way of leaving one.
    (when (actions/desktop?)
      [:button {:label "Quit" :on-click actions/quit!}])]))
