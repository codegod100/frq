(ns frq.edits
  "Rewriting a line that is already said.

  A message keeps the id it was born with across every revision, which is what
  keeps its reactions, replies and pins attached to it. So an edit is not a new
  line: it replaces the one it names, in place, under that line's own id.

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

  `decorate` is applied to the rewritten message, for whatever the caller
  derives from the text it now carries — the desktop re-reads the picture links
  out of it there. `frq.media` is not portable and this does not need it to be."
  ([channels channel msgid from text]
   (apply-edit channels channel msgid from text identity))
  ([channels channel msgid from text decorate]
   (if-not (and channel msgid)
     {:channels channels :result :absent}
     (let [msgs (get-in channels [channel :messages])]
       (if-not msgs
         {:channels channels :result :absent}
         (let [result (volatile! :absent)
               msgs' (mapv (fn [msg]
                             (if (= msgid (:id msg))
                               (if (= (str/lower-case (or (:from msg) ""))
                                      (str/lower-case (or from "")))
                                 (do (vreset! result :applied)
                                     (decorate (assoc msg
                                                      :text text
                                                      :edited? true)))
                                 (do (vreset! result :refused) msg))
                               msg))
                           msgs)]
           {:channels (assoc-in channels [channel :messages] msgs')
            :result @result}))))))
