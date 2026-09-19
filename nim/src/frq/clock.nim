## Server time, in the reader's own zone.
##
## Transcribed from `common/frq/clock.cljc`, arithmetic and all. The date
## conversions are Howard Hinnant's algorithms rather than a call into a date
## library, which is what let the Clojure version be shared between two
## compilers and is just as useful here: eleven lines with no dependency and
## no zone database.
##
## The zone itself is the one thing that is not arithmetic. `localOffsetSeconds`
## asks the host, because finding it is four platform-specific guesses on Linux
## and one property read on Android — and an offset rather than a zone name
## because the offset moves twice a year, and a backlog read in November
## carries messages from August.

import std/[math, strutils, times]

# `floorDiv` and `floorMod` come from std/math. They round down where `div`
# and `mod` round toward zero, which for a day number before 1970 is a
# different day — this module had its own copies until it turned out the
# stdlib's have exactly these semantics.
export floorDiv, floorMod

func daysFromCivil*(y0, m, d: int64): int64 =
  ## Hinnant's algorithm: a civil date to a day number since the epoch.
  let y = if m <= 2: y0 - 1 else: y0
  let era = floorDiv(if y >= 0: y else: y - 399, 400)
  let yoe = y - era * 400
  let doy = (153 * (m + (if m > 2: -3 else: 9)) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

func civilFromDays*(days: int64): (int64, int64, int64) =
  ## The same, the other way round.
  let z = days + 719468
  let era = floorDiv(z, 146097)
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = mp + (if mp < 10: 3 else: -9)
  ((if m <= 2: y + 1 else: y), m, d)

proc nowMs*(): int64 =
  # One `getTime()`, not two: the old form called it twice and could straddle
  # a second boundary between the halves.
  let t = getTime()
  t.toUnix * 1000 + t.nanosecond div 1_000_000

var
  offsetDay = int64.low   ## which UTC day `offsetCache` was computed for
  offsetCache: int64

proc localOffsetSeconds*(epochSecs: int64): int64 =
  ## How far the reader's zone is from UTC at this instant, DST included.
  ##
  ## Nim has a zone database where the ClojureDart version had to ask the host
  ## through `frq.io` — so this is the one function that got simpler in the
  ## move rather than merely moving.
  ##
  ## Memoised per UTC day, because `.local` is a `localtime_r` and that stats
  ## /etc/localtime. Every timestamp on screen asks for this three times, and
  ## the whole tree is rebuilt ten times a second: a busy room was making tens
  ## of thousands of zone lookups a second to render times that had not
  ## changed. The offset moves twice a year and never inside a day, so a
  ## day-granular cache is exact rather than approximate.
  let day = floorDiv(epochSecs, 86400)
  if day != offsetDay:
    offsetDay = day
    offsetCache = fromUnix(epochSecs).local.utcOffset.int64 * -1
  offsetCache

func parseTimeTag*(tags: string): (int64, bool) =
  ## The `time=` value of an IRCv3 tag string as epoch milliseconds.
  ##
  ## Fixed format, always UTC: `2026-08-30T07:05:09.000Z`. Read by hand rather
  ## than through a parser, since this runs once per message of a
  ## hundred-message backlog.
  let i = tags.find("time=")
  if i < 0: return (0'i64, false)
  let s = tags[i + 5 .. ^1]
  if s.len < 19: return (0'i64, false)
  template digits(a, b: int): bool =
    (block:
      var ok = true
      for k in a .. b:
        if k >= s.len or s[k] notin {'0' .. '9'}: ok = false
      ok)
  if not (digits(0, 3) and s[4] == '-' and digits(5, 6) and s[7] == '-' and
          digits(8, 9) and s[10] == 'T' and digits(11, 12) and s[13] == ':' and
          digits(14, 15) and s[16] == ':' and digits(17, 18)):
    return (0'i64, false)
  try:
    let y = s[0 .. 3].parseInt.int64
    let mo = s[5 .. 6].parseInt.int64
    let d = s[8 .. 9].parseInt.int64
    let h = s[11 .. 12].parseInt.int64
    let mi = s[14 .. 15].parseInt.int64
    let sec = s[17 .. 18].parseInt.int64
    let days = daysFromCivil(y, mo, d)
    (1000'i64 * (days * 86400 + h * 3600 + mi * 60 + sec), true)
  except ValueError:
    (0'i64, false)

func pad2(n: int64): string =
  if n < 10: "0" & $n else: $n

proc localParts*(ms: int64): (string, int64, string) =
  ## `(date, hour, minute)` in the reader's zone, the hour on a 24-clock.
  var secs = ms div 1000
  secs += localOffsetSeconds(secs)
  let days = floorDiv(secs, 86400)
  let sod = floorMod(secs, 86400)
  let (y, m, d) = civilFromDays(days)
  ($y & "-" & pad2(m) & "-" & pad2(d), sod div 3600, pad2((sod mod 3600) div 60))

proc clockTime*(ms: int64): string =
  ## A twelve-hour time: `9:05 AM`, `12:30 PM`.
  let (_, hour, minute) = localParts(ms)
  let display = if hour == 0: 12'i64 elif hour > 12: hour - 12 else: hour
  $display & ":" & minute & " " & (if hour < 12: "AM" else: "PM")

proc day*(ms: int64): string = localParts(ms)[0]

proc dayLabel*(ms: int64): string =
  ## The heading for a day's messages: today and yesterday by name, anything
  ## older by date.
  let d = day(ms)
  let today = day(nowMs())
  let yesterday = day(nowMs() - 86_400_000)
  if d == today: "Today"
  elif d == yesterday: "Yesterday"
  else: d
