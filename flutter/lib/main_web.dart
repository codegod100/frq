// `frq.main-web`, not `frq.main_web`: cljd's ns-to-lib maps "." to "/" and
// leaves every other character alone, so the hyphen in the namespace survives
// into the filename. This file keeps the underscore because `-t` names it on
// a command line.
export "cljd-out/frq/main-web.dart" show main;
