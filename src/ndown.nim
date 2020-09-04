import os
import times
import strutils
import uri
import asyncdispatch
import ./download

template die(msg: string; code = 1) =
  stderr.writeLine("Fatal: " & msg)
  quit(code)

#
# parse args
#

var
  optUrl: string
  optN = 1

let paramCount = paramCount()

if paramCount >= 1:
  optUrl = paramStr(1)
if paramCount >= 2:
  optN = paramStr(2).parseInt

#
# validate args
#

if not parseUri(optUrl).isAbsolute:
  die "Absolute URL required."
if optN < 1:
  die "N cannot be less than 1 (obviously...)"

#
# actually do the thing
#

echo "Downloading '", optUrl, "' with N = ", optN, "..."

let startTime = getTime()

discard waitFor download(
  url = optUrl,
  n = optN,
)

let endTime = getTime()

echo "Done in ", endTime - startTime, "."
