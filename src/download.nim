import httpclient
import asyncdispatch
import asyncfutures
import asyncstreams
import strutils
import math
import options
import ./client

const BufSize = 1 shl 20  # 1 MiB

type
  ResourceInfo* = object
    supportsRange*: bool
    contentLength*: Option[int]

  # DownloadResult* = object
  #   success*: bool
  #   filename*: string
  #   httpStatus*: string

  DownloadResult* = bool

  ContentRangeInfo* = object
    unit*: string
    rangeStart*: int
    rangeEnd*: int
    contentLength*: int

proc `and`[T](s: seq[T]): bool =
  for item in s:
    if not bool(item):
      return false
  return true

# proc parseContentRange(contentRange: string): ContentRangeInfo =
#   let spl1 = contentRange.split(' ')
#   result.unit = spl1[0]
#   let spl2 = spl1[1].split('/')
#   result.contentLength = spl2[1].parseInt
#   let spl3 = spl2[0].split('-')
#   result.rangeStart = spl3[0].parseInt
#   result.rangeEnd = spl3[1].parseInt

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

proc getResourceInfo(url: string): Future[ResourceInfo] {.async.} =
  let headers = (await client().head(url)).headers
  return ResourceInfo(
    supportsRange: resourceSupportsRangeRequests(headers),
    contentLength:
      if headers.hasKey("Content-Length"):
        some(headers["Content-Length"].parseInt)
      else:
        none(int)
  )

proc writeRangeToFile(file: File; filePosOrigin: int; response: AsyncResponse): Future[bool] {.async.} =
  var
    buf: array[BufSize, uint8]
    bufPos = 0
    filePos = filePosOrigin

  while true:
    let (hasMore, data) = await response.bodyStream.read()

    for c in data:
      buf[bufPos] = uint8(c)
      bufPos.inc

    if (not hasMore) or (bufPos + data.len > BufSize):  # assuming that data.len is always the same
      echo "writing ", bufPos, " bytes to file at position ", filePos
      file.setFilePos(filePos)
      let bytesWritten = file.writeBytes(buf, 0, bufPos)
      if bytesWritten < bufPos:
        echo "NOT WHOLE BUFFER WRITTEN! ", bytesWritten, " / ", bufPos
      filePos += bufPos
      bufPos = 0

    if not hasMore:
      break

proc download*(url: string; n = 1): Future[DownloadResult] {.async.} =
  var n = n

  let resourceInfo = await getResourceInfo(url)
  var contentLength: int

  if not resourceInfo.supportsRange:
    n = 1

  if resourceInfo.contentLength.isSome:
    contentLength = resourceInfo.contentLength.get
  else:
    contentLength = await guessContentLength(url)
    echo "GUESSED CONTENT-LENGTH AS ", contentLength

  let file = open("myfile", fmWrite)
  var writers: seq[Future[bool]]

  let rangeSize = ceil(contentLength / n).int
  var curRange = 0
  for i in 0..<n:
    let
      rangeStart = curRange * rangeSize
      rangeEnd = min(rangeStart + rangeSize, contentLength) - 1
      headers = newHttpHeaders({
        "Range": "bytes=" & $rangeStart & "-" & $rangeEnd
      })
      response = await client().request(url, HttpGet, headers = headers)

    let w = writeRangeToFile(file, rangeStart, response)
    writers.add(w)
    curRange.inc

  let stati = await all(writers)
  return stati.and

# when isMainModule:
#   # const Url = "https://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_1080p_stereo.ogg"
#   # const Url = "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"
#   # const Url = "https://github.com/FredJul/Flym/archive/v2.4.0.zip"
#   const Url = "https://github.com/gpodder/gpodder/releases/download/3.10.16/windows-gpodder-3.10.16-installer.exe"

#   let downloadResult = waitFor download(Url, 2)
