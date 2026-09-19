## The date arithmetic, against the cases that are easy to get wrong.

import std/unittest
import frq/clock

suite "the civil-date round trip":
  test "the epoch":
    check daysFromCivil(1970, 1, 1) == 0
    check civilFromDays(0) == (1970'i64, 1'i64, 1'i64)

  test "round-trips every day from 1901 to 2052":
    # The same range the Clojure was checked against java.time.LocalDate over.
    var d = daysFromCivil(1901, 1, 1)
    let last = daysFromCivil(2052, 12, 31)
    while d <= last:
      let (y, m, dd) = civilFromDays(d)
      check daysFromCivil(y, m, dd) == d
      d += 1

  test "leap days exist and non-leap ones do not":
    check civilFromDays(daysFromCivil(2024, 2, 29)) == (2024'i64, 2'i64, 29'i64)
    # 2100 is not a leap year; Feb 29 there rolls into March.
    check civilFromDays(daysFromCivil(2100, 2, 29)) == (2100'i64, 3'i64, 1'i64)

  test "before the epoch, where rounding toward zero would be a day out":
    check civilFromDays(daysFromCivil(1969, 12, 31)) == (1969'i64, 12'i64, 31'i64)
    check daysFromCivil(1969, 12, 31) == -1

suite "floorDiv":
  test "rounds down rather than toward zero":
    check floorDiv(-1, 86400) == -1
    check floorDiv(7, 2) == 3
    check floorDiv(-7, 2) == -4
  test "floorMod is never negative for a positive divisor":
    check floorMod(-1, 86400) == 86399

suite "parseTimeTag":
  # The expected values are python's `datetime(...).timestamp()`, not arithmetic
  # done by hand — the first draft of this test was twelve days out and the
  # implementation was right.
  test "a real tag":
    let (ms, ok) = parseTimeTag("time=2026-08-30T07:05:09.000Z")
    check ok
    check ms == 1788073509000'i64

  test "finds it among other tags":
    let (ms, ok) = parseTimeTag("account=alice;time=2026-08-30T07:05:09.000Z;msgid=x")
    check ok
    check ms == 1788073509000'i64

  test "no tag at all":
    check not parseTimeTag("account=alice")[1]
    check not parseTimeTag("")[1]

  test "a malformed value is refused rather than guessed at":
    check not parseTimeTag("time=not-a-time")[1]
    check not parseTimeTag("time=2026-08-30")[1]
