(ns frq.clock
  "Wall-clock time, in the reader's own zone.

  Messages carry an IRCv3 `time` tag in UTC; a channel is read in local time.
  Everything between those two is arithmetic, which is why this namespace is
  shared: the only thing it asks the platform for is the offset at an instant
  and the current time, both through `frq.io`.

  Finding the zone used to live here, and it was four guesses deep — TZ, then
  the target of /etc/localtime, then the file itself by path, then Android's
  system property. That is a libc question with a different answer on each
  side, so it moved to the backends: `frq.io.jolt` still carries the whole
  ladder, and `frq.io.dart` answers it with one call, because Dart carries the
  zone in its runtime."
  (:require [frq.io :as io]))

(defn now-ms [] (quot (io/wall-nanos) 1000000))

(defn parse-time-tag
  "The `time=` value of an IRCv3 tag string as epoch milliseconds, or nil.

  Fixed format, always UTC: `2026-08-30T07:05:09.000Z`. Read by hand rather
  than through a parser, since this runs once per message of a hundred-message
  backlog."
  [tags]
  (when-let [[_ y mo d h mi s] (re-find #"time=(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})"
                                        (or tags ""))]
    (let [[y mo d h mi s] (map parse-long [y mo d h mi s])
          ;; days from the civil date, by Howard Hinnant's algorithm
          y (if (<= mo 2) (dec y) y)
          era (quot (if (>= y 0) y (- y 399)) 400)
          yoe (- y (* era 400))
          doy (+ (quot (+ (* 153 (+ mo (if (> mo 2) -3 9))) 2) 5) (dec d))
          doe (+ (* yoe 365) (quot yoe 4) (- (quot yoe 100)) doy)
          days (+ (* era 146097) doe -719468)]
      (* 1000 (+ (* days 86400) (* h 3600) (* mi 60) s)))))

(defn- floor-div
  "`quot` rounds toward zero and this rounds down, which for a day number
  before 1970 is a different day.

  Written out rather than taken from the host: `Math/floorDiv` is Java, and
  this namespace is compiled by ClojureDart too, where there is no Math class
  to call into. The same reason `frq.io` exists, one scale down."
  [a b]
  (let [q (quot a b)
        r (rem a b)]
    (if (or (zero? r) (= (neg? r) (neg? b))) q (dec q))))

(defn- floor-mod [a b] (- a (* b (floor-div a b))))

(defn- civil-from-days
  "`[y m d]` for a day number since the epoch — Hinnant's algorithm the other
  way round, which is the direction `parse-time-tag` does not go.

  This was `jolt.time.local/local-dt` and a `subs` off the string it printed.
  Two problems with that: it is jolt's, so the namespace could not be shared,
  and it built a formatted date only to take it apart again. The arithmetic is
  eleven lines and the same on both platforms."
  [days]
  (let [z (+ days 719468)
        era (floor-div z 146097)
        doe (- z (* era 146097))
        yoe (quot (+ (- doe (quot doe 1460)) (quot doe 36524) (- (quot doe 146096))) 365)
        y (+ yoe (* era 400))
        doy (- doe (+ (* 365 yoe) (quot yoe 4) (- (quot yoe 100))))
        mp (quot (+ (* 5 doy) 2) 153)
        d (+ (- doy (quot (+ (* 153 mp) 2) 5)) 1)
        m (+ mp (if (< mp 10) 3 -9))]
    [(if (<= m 2) (inc y) y) m d]))

(defn- pad2 [n] (if (< n 10) (str "0" n) (str n)))

(defn- local-parts
  "`[date hour minute]` in the reader's zone, the hour on a 24-clock."
  [ms]
  (let [secs (quot ms 1000)
        secs (+ secs (io/local-offset-seconds secs))
        days (floor-div secs 86400)
        sod (floor-mod secs 86400)
        [y m d] (civil-from-days days)]
    [(str y "-" (pad2 m) "-" (pad2 d))
     (quot sod 3600)
     (pad2 (quot (mod sod 3600) 60))]))

(defn clock-time
  "A twelve-hour time: `9:05 AM`, `12:30 PM`."
  [ms]
  (let [[_ hour minute] (local-parts ms)
        display (cond (zero? hour) 12
                      (> hour 12) (- hour 12)
                      :else hour)]
    (str display ":" minute " " (if (< hour 12) "AM" "PM"))))

(defn day [ms] (first (local-parts ms)))

(defn day-label
  "The heading for a day's messages: today and yesterday by name, anything
  older by date."
  [ms]
  (let [d (day ms)
        today (day (now-ms))
        yesterday (day (- (now-ms) 86400000))]
    (cond (= d today) "Today"
          (= d yesterday) "Yesterday"
          :else d)))
