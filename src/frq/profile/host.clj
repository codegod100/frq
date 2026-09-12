(ns frq.profile.host
  "How this half fetches a profile, and the picture that goes with one.

  `frq.profile` under common/ is what a profile *is* — the cache, the fields,
  the URL, the counts, and the press that opens one. What is left here is the
  two things that genuinely differ by host. The fetch, because a `future` and a
  blocking request is this backend's answer to a question the other one answers
  by awaiting. And the avatar, because the desktop downloads a file where the
  phone hands over a CDN URL.

  The shared names are re-exported so callers did not have to move."
  (:require [frq.atproto :as atproto]
            [frq.avatars :as avatars]
            [frq.profile :as profile]))

(def viewing profile/viewing)
(def tick profile/tick)
(def entry profile/entry)
(def close! profile/close!)
(def web-url profile/web-url)
(def stats-line profile/stats-line)
(def truncate profile/truncate)

(profile/install-fetch!
 (fn [actor]
   (future
     (profile/deliver-profile!
      actor
      (try
        (let [{:keys [host path]} (profile/profile-req actor)]
          (atproto/request host path nil))
        (catch Exception _ nil))))))

(defn- with-avatar!
  "The picture too. The chat asks for one when a line arrives, but a profile
  can be opened on someone whose avatar never landed, and it paints a bigger
  one than the column it was fetched for."
  [actor]
  (when (seq actor) (avatars/fetch! actor #(swap! tick inc))))

(defn open!
  "Look at someone. `actor` is their DID or handle, or nil for a guest."
  [nick actor]
  (with-avatar! actor)
  (profile/open! nick actor))
