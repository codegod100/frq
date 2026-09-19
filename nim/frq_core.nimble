version       = "0.1.0"
author        = "nandi"
description   = "The portable core of frq, as a C-callable library"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run the test suite":
  exec "nim c -r --hints:off tests/tircparse.nim"
