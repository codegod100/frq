## A `draft/multiline` batch in, one message out.

import std/unittest
import frq/[ircparse, multiline]

proc run(lines: varargs[string]): seq[IrcLine] =
  var a: Assembler
  for l in lines: result.add a.feed(parseLine(l))

suite "putting a multiline message back together":
  test "a batch comes out as one PRIVMSG with the opener's tags":
    let got = run(
      "@msgid=m1;time=2026-09-25T13:20:50.000Z;account=did:plc:z " &
        ":zapnap BATCH +ml1 draft/multiline #freeq-dev",
      "@batch=ml1 :zapnap PRIVMSG #freeq-dev :first",
      "@batch=ml1 :zapnap PRIVMSG #freeq-dev :",
      "@batch=ml1 :zapnap PRIVMSG #freeq-dev :third",
      ":irc.freeq.at BATCH -ml1")
    check got.len == 1
    check got[0].command == "PRIVMSG"
    check got[0].params == @["#freeq-dev", "first\n\nthird"]
    check tagValue(got[0].tags, "msgid") == ("m1", true)
    check got[0].account == "did:plc:z"
    check nickOf(got[0].prefix) == "zapnap"

  test "a concat line continues the one before it":
    let got = run(
      "@msgid=m1 :z BATCH +ml1 draft/multiline #r",
      "@batch=ml1 :z PRIVMSG #r :a long li",
      "@batch=ml1;draft/multiline-concat :z PRIVMSG #r :ne",
      ":s BATCH -ml1")
    check got[0].params[^1] == "a long line"

  test "nested in a history batch, and everything else passes through":
    let got = run(
      ":s BATCH +ch1 chathistory #r",
      "@batch=ch1;msgid=a :bob!b@h PRIVMSG #r :one line",
      "@batch=ch1;msgid=m1 :z BATCH +ml1 draft/multiline #r",
      "@batch=ml1 :z PRIVMSG #r :x",
      "@batch=ml1 :z PRIVMSG #r :y",
      "@batch=ch1 :s BATCH -ml1",
      ":s BATCH -ch1")
    check got.len == 4
    check got[0].command == "BATCH"
    check got[1].params[^1] == "one line"
    check got[2].params[^1] == "x\ny"
    check got[3].command == "BATCH"

  test "the older inline form has its escaped breaks undone":
    let got = run("@+freeq.at/multiline;msgid=m :z PRIVMSG #r :a\\nb")
    check got[0].params[^1] == "a\nb"
