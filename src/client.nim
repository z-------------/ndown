import httpclient
import ./pkgVersion

let headers = newHttpHeaders({
  "User-Agent": "ndown/" & $PkgVersion,
})

proc client*(): AsyncHttpClient =
  newAsyncHttpClient(headers = headers)
