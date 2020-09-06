import httpclient
import ./pkgVersion

proc client*(): AsyncHttpClient =
  newAsyncHttpClient(headers = newHttpHeaders({
    "User-Agent": "ndown/" & $PkgVersion,
  }))
