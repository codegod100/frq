(ns frq.screens.connect
  "The connect screen, shared.

  The first of `frq.app`'s screens to move out of it, and the move was a
  rename rather than a rewrite: this is the same hiccup it always was, reading
  `frq.cells` instead of `frq.state` and calling `frq.actions` instead of the
  reducers behind it. `frq.app` requires it and renders it exactly where its
  own copy used to be, so the desktop draws this file and so does the phone.

  Which is the point of the whole arrangement. glimmer's components never knew
  what was under the reconciler; now they do not know what is under the *app*
  either, and a screen is portable as soon as the cells it reads and the
  actions it calls are."
  (:require [frq.actions :as actions]
            [frq.cells :as cells]))

(def transport-note
  "What the foot of the screen says about the transport, which is the one
  sentence here that is not the same on both.

  It is a reader conditional rather than a seam because it is a compile-time
  fact: jolt reaches OpenSSL through the dynamic loader, and Android ships no
  public libssl, so :6697 was unreachable there and the screen said so. Under
  ClojureDart TLS is in the Dart runtime — `SecureSocket`, nothing to load —
  and that sentence would now be a lie.

  Sign-in itself is no longer one of those differences: `frq.irc.handshake`
  drives SASL from common/, so both halves sign in the same way."
  #?(:cljd "TLS comes from dart:io, so :6697 works here; untick it for a plain :6667 listener."
     :jolt "TLS rides jolt's OpenSSL bindings; untick it for a plain :6667 listener. Sign-in needs TLS, so it is desktop-only."))

(defn error-note
  "Always a node, never nil.

  A conditional child that disappears shifts every sibling after it, and the
  reconciler matches children by position — so an error appearing mid-screen
  would patch the header into a card. A stable wrapper with a stable key keeps
  the shape of the tree fixed and only its contents changing."
  []
  [:vbox {:key :error-note :spacing 6}
   (when-let [e @cells/error]
     [:card {}
      [:label {:label (str "⚠ " e)}]
      [:button {:label "Dismiss" :on-click #(reset! cells/error nil)}]])])

;; ---------------------------------------------------------------- connect

(defn mode-tabs []
  [:hbox {:spacing 8}
   (for [[k label] [[:guest "Guest"] [:bluesky "Bluesky"] [:app-password "App password"]]]
     [:button {:key k
               :label label
               :kind (if (= k @cells/auth-mode) :primary :default)
               :on-click #(reset! cells/auth-mode k)}])])

(defn server-fields []
  [:vbox {:spacing 6}
   ;; Every :entry carries a :key. glimmer matches children by position when
   ;; one is absent, so this changes nothing on the desktop — but a backend
   ;; that keeps a text controller per field needs a stable name for it, and
   ;; without one the host and the port shared a controller and both showed
   ;; the port. See frq.hiccup.
   [:label {:label "Server"}]
   [:hbox {:spacing 8}
    [:entry {:key :host
             :text @cells/form-host
             :width-request 220
             :placeholder "host"
             :on-change #(reset! cells/form-host %)}]
    [:entry {:key :port
             :text @cells/form-port
             :width-request 90
             :placeholder "6697"
             :on-change #(reset! cells/form-port %)}]]
   [:checkbutton {:label "TLS"
                  :active @cells/form-tls?
                  :on-toggled #(do (swap! cells/form-tls? not)
                                   (reset! cells/form-port
                                           (if @cells/form-tls? "6697" "6667")))}]])

(defn connect-action []
  (if @cells/connecting?
    [:hbox {:spacing 8}
     [:spinner {}]
     [:dim-label {:label @cells/status}]]
    [:hbox {:spacing 8}
     [:button {:label "Connect" :kind :primary :on-click actions/connect!}]
     [:dim-label {:label @cells/status}]]))

(defn connect-screen []
  [:page {:max-width 520}
   [:title {:label "frq"}]
   [:dim-label {:label "freeq client — guest, or your Bluesky identity."}]
   [error-note]
   [:card {}
    [mode-tabs]
    (case @cells/auth-mode
      :bluesky
      [:vbox {:spacing 6}
       [:title-2 {:label "Sign in with Bluesky"}]
       [:dim-label {:label "Opens your browser for AT Protocol OAuth. freeq's broker hands back a token; no password passes through frq."}]
       [:label {:label "Handle"}]
       [:entry {:key :handle
             :text @cells/form-handle
                :width-request 320
                :placeholder "alice.bsky.social"
                :on-change #(reset! cells/form-handle %)}]
       [:vbox {:key :remembered :spacing 4}
        (when @cells/broker-token
          [:vbox {:spacing 4}
           [:dim-label {:label "Session remembered — Connect will not need the browser."}]
           [:button {:label "Forget saved session" :on-click actions/forget-session!}]])]
       [:vbox {:key :login-url :spacing 4}
        (when-let [url @cells/login-url]
          [:vbox {:spacing 4}
           [:dim-label {:label "If the browser did not open, visit:"}]
           [:label {:label url}]])]]

      :app-password
      [:vbox {:spacing 6}
       [:title-2 {:label "Sign in with an app password"}]
       [:dim-label {:label "No browser. Your app password goes to your own PDS; freeq is handed the session it mints."}]
       [:label {:label "Handle"}]
       [:entry {:key :handle
             :text @cells/form-handle
                :width-request 320
                :placeholder "alice.bsky.social"
                :on-change #(reset! cells/form-handle %)}]
       [:label {:label "App password"}]
       [:entry {:key :app-password
             :text @cells/form-app-password
                :width-request 320
                :placeholder "xxxx-xxxx-xxxx-xxxx"
                :on-change #(reset! cells/form-app-password %)}]
       [:dim-label {:label "Make one at bsky.app → Settings → App Passwords."}]]

      [:vbox {:spacing 6}
       [:title-2 {:label "Connect as guest"}]
       [:label {:label "Nick"}]
       [:entry {:key :nick
             :text @cells/form-nick
                :width-request 320
                :placeholder "your nick"
                :on-change #(reset! cells/form-nick %)}]])
    [server-fields]
    [:separator {}]
    [connect-action]]
   [:dim-label {:label transport-note}]])
