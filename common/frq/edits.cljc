(ns frq.edits
  "Rewriting a line that is already said.

  A message keeps the id it was born with across every revision, which is what
  keeps its reactions, replies and pins attached to it. So an edit is not a new
  line: it replaces the one it names, in place, under that line's own id.

  The revision's own msgid is kept beside it rather than dropped. Nothing else
  refers to it, this used to say, which was very nearly true and wrong where
  it counted: someone answering a line that has already been rewritten replies
  to the wording in front of them, so the `+reply` names the revision. A
  client that threw that id away held the message under a name no reply used,
  and every such answer came out as a chip pointing at nothing.

  Pure over the channels map, like `frq.members` and `frq.reactions`, and
  shared for the same reason — who may rewrite what is the server's rule and
  neither half of frq gets a say in it."
  (:require [clojure.string :as str]))

(defn apply-edit
  "The revision folded into the buffer it belongs to.

  Answers `{:channels :result}`, where the result says what became of it:
  `:applied`; `:refused` for one that was not the sender's to make; or
  `:absent` when no line here has that id — an edit of something older than the
  backlog we asked for, which is the one case the caller shows as a line of its
  own rather than losing what it says.

  Only the sender may rewrite their own line, so an edit whose nick is not the
  one on the message is dropped. The server checks authorship too, and a client
  that believed the wire alone would let a hostile relay put words in somebody
  else's mouth.

  `opts` are `:decorate`, applied to the rewritten message for whatever the
  caller derives from the text it now carries — the desktop re-reads the
  picture links out of it there; `frq.media` is not portable and this does not
  need it to be — and `:revision`, the msgid the server gave the edit itself,
  which joins `:edit-ids` on the message so a reply naming it still finds the
  line it belongs to. See `frq.rooms/answers-to?`."
  ([channels channel msgid from text]
   (apply-edit channels channel msgid from text nil))
  ([channels channel msgid from text opts]
   (if-not (and channel msgid)
     {:channels channels :result :absent}
     (let [{:keys [decorate revision]} (if (map? opts) opts {:decorate opts})
           decorate (or decorate identity)
           msgs (get-in channels [channel :messages])]
       (if-not msgs
         {:channels channels :result :absent}
         (let [result (volatile! :absent)
               msgs' (mapv (fn [msg]
                             (if (= msgid (:id msg))
                               (if (= (str/lower-case (or (:from msg) ""))
                                      (str/lower-case (or from "")))
                                 (do (vreset! result :applied)
                                     (decorate (cond-> (assoc msg
                                                              :text text
                                                              :edited? true)
                                                 revision
                                                 (update :edit-ids
                                                         (fnil conj #{})
                                                         revision))))
                                 (do (vreset! result :refused) msg))
                               msg))
                           msgs)]
           {:channels (assoc-in channels [channel :messages] msgs')
            :result @result}))))))
