import httpclient
import asyncdispatch
import asyncfutures
import asyncstreams
import strutils
import math
import options
import uri
import locks
import ./client

var mutex: Lock
mutex.initLock()

type
  ResourceInfo* = object
    supportsRange*: bool
    contentLength*: Option[int]
    filename*: string

  DownloadResult* = bool

  ContentRangeInfo* = object
    unit*: string
    rangeStart*: int
    rangeEnd*: int
    contentLength*: int

  ThreadArgs = tuple[url: string; f: File; rStart, rEnd: int]

proc parseContentDisposition(contentDisposition: string): Option[string] =
  let
    spl1 = contentDisposition.split("; ")
    dispositionType = spl1[0]
  if dispositionType != "attachment":
    return none(string)
  var filename = spl1[1].split('=')[1]
  if filename[0] == '"' and filename[filename.high] == '"':
    filename = filename.substr(1, filename.high - 1)
  return some(filename)

proc resourceSupportsRangeRequests(headers: HttpHeaders): bool =
  if not headers.hasKey("Accept-Ranges"):
    return false
  let acceptRanges = headers["Accept-Ranges"].toLowerAscii
  if acceptRanges == "none":
    return false
  if acceptRanges != "bytes":  # I can't be fucked to support anything else. It's the only unit defined in RFC 7233 anyway.
    return false
  return true

proc guessContentLength(url: string): Future[int] {.async.} =
  ## Resources with `Transfer-Encoding: chunked` do not include Content-Length.
  ## So we try to guess it by requesting successively higher small ranges
  ## until the server tells us we are out of range.
  var
    c = client()
    curGuess = 2 * (1 shl 20)

  while true:
    let response = await c.request(
      url, HttpGet,
      headers = newHttpHeaders({ "Range": "bytes=" & $curGuess & "-" & $(curGuess + 1) })
    )
    if response.status == "416" or (await response.body).len == 0:
      break
    else:
      curGuess *= 2

  return curGuess

proc getFilename(url: string): string =
  let
    uri = url.parseUri
    path = uri.path.split('/')
  path[path.len - 1]

proc getResourceInfo(url: string): Future[ResourceInfo] {.async.} =
  var ri = ResourceInfo()
  let headers = (await client().head(url)).headers

  ri.supportsRange = resourceSupportsRangeRequests(headers)

  ri.contentLength =
    if headers.hasKey("Content-Length"):
      some(headers["Content-Length"].parseInt)
    else:
      none(int)

  var gotFilename = false
  if headers.hasKey("Content-Disposition"):
    let filename = parseContentDisposition(headers["Content-Disposition"])
    if filename.isSome:
      ri.filename = filename.get
      gotFilename = true
  if not gotFilename:
    ri.filename = getFilename(url)

  return ri

proc threadProc(args: ThreadArgs) {.thread.} =
  let
    url = args.url
    file = args.f
    rangeStart = args.rStart
    rangeEnd = args.rEnd
    headers = newHttpHeaders({
      "Range": "bytes=" & $rangeStart & "-" & $rangeEnd
    })
    responseFut = client().request(url, HttpGet, headers = headers)
    response = waitFor responseFut
  var
    hasMore = true
    filePos = rangeStart
  while hasMore:
    let readResult = waitFor response.bodyStream.read()
    hasMore = readResult[0]
    mutex.acquire()
    file.setFilePos(filePos)
    file.write(readResult[1])
    mutex.release()
    filePos += readResult[1].len

proc download*(url: string; n = 1): Future[DownloadResult] {.async.} =
  var n = n

  let resourceInfo = await getResourceInfo(url)
  var contentLength: int

  if not resourceInfo.supportsRange:
    echo "RESOURCE DOESN'T SUPPORT RANGE"
    n = 1

  if resourceInfo.contentLength.isSome:
    contentLength = resourceInfo.contentLength.get
  else:
    contentLength = await guessContentLength(url)
    echo "GUESSED CONTENT-LENGTH AS ", contentLength

  let file = open(resourceInfo.filename, fmWrite)
  var
    writers = newSeq[Thread[ThreadArgs]](n)
    writerIdx = 0
    ranges: seq[(int, int)]

  let rangeSize = ceil(contentLength / n).int
  var curRange = 0
  for i in 0..<n:
    let
      rangeStart = curRange * rangeSize
      rangeEnd = min(rangeStart + rangeSize, contentLength) - 1
    ranges.add((rangeStart, rangeEnd))
    curRange.inc
  
  while ranges.len > 0:
    let (rangeStart, rangeEnd) = ranges[0]
    ranges.delete(0)
    createThread(writers[writerIdx], threadProc, (url, file, rangeStart, rangeEnd))
    writerIdx = (writerIdx + 1) mod n
  
  for thread in writers:
    thread.joinThread()
