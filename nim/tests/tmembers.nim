## Membership, modes, and Tab completion.

import std/[sequtils, tables, unittest]
import frq/members

suite "splitPrefix":
  test "a mode in front of a nick":
    check splitPrefix("@alice") == ("@", "alice")
    check splitPrefix("+bob") == ("+", "bob")
  test "a bare nick":
    check splitPrefix("carol") == ("", "carol")
  test "an empty entry":
    check splitPrefix("") == ("", "")

suite "withNames":
  test "folds a 353 into the pending list":
    var acc = initTable[string, string]()
    acc.withNames("@alice bob +carol")
    check acc["alice"] == "@"
    check acc["bob"] == ""
    check acc["carol"] == "+"

  test "several replies accumulate rather than replace":
    # NAMES arrives over as many lines as it takes.
    var acc = initTable[string, string]()
    acc.withNames("@alice")
    acc.withNames("bob")
    check acc.len == 2

  test "runs of spaces do not become members":
    var acc = initTable[string, string]()
    acc.withNames("alice   bob")
    check acc.len == 2

suite "withMode":
  setup:
    var users = {"alice": "", "bob": "", "carol": ""}.toTable

  test "granting op":
    users.withMode("+o", @["alice"])
    check users["alice"] == "@"

  test "taking it away":
    users.withMode("+o", @["alice"])
    users.withMode("-o", @["alice"])
    check users["alice"] == ""

  test "several at once, in order":
    users.withMode("+ov", @["alice", "bob"])
    check users["alice"] == "@"
    check users["bob"] == "+"

  test "a mode naming nobody still eats its argument":
    # The rule this exists for: `+ko secret alice` sets a key and then ops
    # alice. Reading the next letter's nick out of the wrong place would put
    # the op on whoever `secret` happened to match.
    users.withMode("+ko", @["secret", "alice"])
    check users["alice"] == "@"
    check users["bob"] == ""

  test "a mode for somebody who is not here changes nothing":
    users.withMode("+o", @["stranger"])
    check "stranger" notin users

  test "removing a mode takes no argument on some servers, and we do not eat one":
    users.withMode("+o", @["alice"])
    users.withMode("-l+v", @["bob"])
    check users["bob"] == "+"

suite "memberList":
  test "ops first, then alphabetically":
    let users = {"zoe": "", "alice": "", "bob": "@", "carol": "+"}.toTable
    check memberList(users).mapIt(it.nick) == @["bob", "carol", "alice", "zoe"]

  test "the prefix order is the server's":
    let users = {"v": "+", "o": "@", "q": "~", "plain": ""}.toTable
    check memberList(users).mapIt(it.nick) == @["q", "o", "v", "plain"]

  test "case does not decide the alphabetical order":
    let users = {"Bob": "", "alice": ""}.toTable
    check memberList(users).mapIt(it.nick) == @["alice", "Bob"]

suite "completeNick":
  let nicks = @["alice", "alison", "bob"]

  test "one match is taken whole":
    check completeNick("hi bo", nicks) == ("hi bob ", true)

  test "at the start of a line it is an address, elsewhere a mention":
    # `eve: watch this` reads as talking TO eve; mid-sentence it is just a
    # name, so it gets a plain space.
    check completeNick("bo", nicks)[0] == "bob: "
    check completeNick("hi bo", nicks)[0] == "hi bob "

  test "several matches go as far as they agree":
    check completeNick("al", nicks) == ("ali", true)

  test "no match leaves the draft alone":
    check completeNick("zz", nicks) == ("zz", false)

  test "nothing to complete":
    check completeNick("", nicks)[1] == false
    check completeNick("hi ", nicks)[1] == false

  test "case is ignored, and the nick's own case lands":
    check completeNick("hi BO", nicks) == ("hi bob ", true)

  test "a completed word is not completed again":
    # "ali" already agrees with both; there is nothing more to add.
    check completeNick("ali", nicks)[1] == false
