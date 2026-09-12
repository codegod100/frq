(ns frq.irc.mutate
  "Changing a message that is already said, as lines to send.

  The same bargain `frq.irc.handshake` strikes: what to send is shared, the
  sending is the caller's. A reaction is a TAGMSG carrying tags and no body,
  and every part of building one is arithmetic over strings — the tag names
  freeq reads, the escaping IRCv3 asks for, and the signature `frq.msgsig`
  mints. None of that is a socket, and none of it differs between a desktop
  reader thread and a phone's Stream.

  Signed, because from an account freeq will not take it otherwise: an
  unsigned mutation comes back as `FAIL TAGMSG SIGNATURE_REQUIRED` and the
  message stays as it was. A guest has no key and sends none, which the
  server allows and the tags simply omit."
  (:require [clojure.string :as str]
            [frq.irc.parse :as parse]
            [frq.msgsig :as msgsig]))

(defn tag-line
  "`tags` in front of `rest-of-line`, escaped the way IRCv3 wants them.

  Sent in no particular order — the server reads them by name."
  [tags rest-of-line]
  (str "@" (str/join ";" (for [[k v] tags]
                           (str k "=" (parse/escape-tag-value v))))
       " " rest-of-line))

(defn react-line
  "Put `emoji` on `msgid`, for everyone in `target` to see.

  `peer-did` is who the DM is with, and is what a DM signature names the
  conversation by — freeq names a DM by both DIDs rather than by a nick, and
  nothing else in a buffer says which account the other side is. nil in a
  channel, which is named by itself."
  ([target msgid emoji] (react-line target msgid emoji nil))
  ([target msgid emoji peer-did]
   (tag-line (merge {"+react" emoji "+reply" msgid}
                    (msgsig/mutation-tags "react" target msgid emoji peer-did))
             (str "TAGMSG " target))))

(defn unreact-line
  "Take it off again. The server keys the removal by DID where there is one, so
  it survives a nick change and cannot be done on someone else's behalf.

  Signed like the reaction it undoes — taking a pill off is as much a change to
  a message as putting one on, and the server asks for the same proof."
  ([target msgid emoji] (unreact-line target msgid emoji nil))
  ([target msgid emoji peer-did]
   (tag-line (merge {"+freeq.at/unreact" emoji "+reply" msgid}
                    (msgsig/mutation-tags "unreact" target msgid emoji peer-did))
             (str "TAGMSG " target))))
