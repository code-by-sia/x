// std/http — a minimal HTTP/1.1 client over std/net. Plain http:// always works;
// https:// requires the toolchain built with XC_TLS=1 (OpenSSL).
//   let r = http.get("https://example.com/")
//   if isOk(r) { system.stdout.writeln(r.value.body) }
namespace http

import "std/net.xi"
import "std/text.xi"
import "std/convert.xi"

extern "C" {
    mapper xstd_https_fetch(host: String, port: Integer, request: String) -> String
}

type Url      = { host: String, port: Integer, path: String, tls: Bool }
// `headers` is the raw header block (CRLF-separated "Key: Value" lines);
// use http.header(resp, name) to look one up.
type Response = { status: Integer, headers: String, body: String }

// Parse "http(s)://host[:port]/path".
mapper parseUrl(u: String) -> Url! {
    let rest = u
    let tls = false
    let port = 80
    if text.startsWith(rest, "http://") {
        rest = text.substring(rest, 7, text.length(rest))
    } else {
        if text.startsWith(rest, "https://") {
            rest = text.substring(rest, 8, text.length(rest))
            tls = true
            port = 443
        }
    }
    let slash = text.indexOf(rest, "/")
    let authority = rest
    let path = "/"
    if slash >= 0 {
        authority = text.substring(rest, 0, slash)
        path = text.substring(rest, slash, text.length(rest))
    }
    let host = authority
    let colon = text.indexOf(authority, ":")
    if colon >= 0 {
        host = text.substring(authority, 0, colon)
        let ps = text.substring(authority, colon + 1, text.length(authority))
        let pr = convert.parseInteger(ps)
        if isErr(pr) { return err("bad port in url: " + u) }
        port = pr.value
    }
    if text.length(host) == 0 { return err("missing host in url: " + u) }
    return ok(Url { host: host, port: port, path: path, tls: tls })
}

// Parse a raw HTTP response into status / headers / body.
mapper parseResponse(raw: String) -> Response! {
    if text.length(raw) == 0 { return err("empty response") }
    let sep = text.indexOf(raw, "\r\n\r\n")
    let head = raw
    let body = ""
    if sep >= 0 {
        head = text.substring(raw, 0, sep)
        body = text.substring(raw, sep + 4, text.length(raw))
    }
    let lines = text.split(head, "\r\n")
    let statusLine = lines.data[0]
    let parts = text.split(statusLine, " ")
    if parts.len < 2 { return err("malformed status line: " + statusLine) }
    let sr = convert.parseInteger(parts.data[1])
    if isErr(sr) { return err("bad status code: " + parts.data[1]) }
    // header block = everything after the first line
    let headers = ""
    let firstLen = text.length(statusLine) + 2     // + CRLF
    if text.length(head) > firstLen {
        headers = text.substring(head, firstLen, text.length(head))
    }
    return ok(Response { status: sr.value, headers: headers, body: body })
}

// Look up a response header by name (case-insensitive); "" if absent.
mapper header(resp: Response, name: String) -> String {
    let lines = text.split(resp.headers, "\r\n")
    let target = text.toLower(name)
    let i = 0
    while i < lines.len {
        let line = lines.data[i]
        let c = text.indexOf(line, ":")
        if c >= 0 {
            let key = text.toLower(text.trim(text.substring(line, 0, c)))
            if key == target {
                return text.trim(text.substring(line, c + 1, text.length(line)))
            }
        }
        i = i + 1
    }
    return ""
}

// Send one request and read the full response (uses Connection: close).
producer request(method: String, url: String, body: String, contentType: String) -> Response! {
    let noHeaders: String[] = []
    return requestWith(method, url, body, contentType, noHeaders)
}

// Like request, but with extra request headers (each a "Name: Value" string, no
// CRLF). Use it to carry a traceparent for distributed tracing, an auth token,
// and so on.
producer requestWith(method: String, url: String, body: String, contentType: String, extraHeaders: String[]) -> Response! {
    let ur = parseUrl(url)
    if isErr(ur) { return err(ur.err) }
    let u = ur.value

    let req = method + " " + u.path + " HTTP/1.1\r\n"
            + "Host: " + u.host + "\r\n"
            + "User-Agent: x-http/0.1\r\n"
            + "Connection: close\r\n"
    let h = 0
    while h < extraHeaders.len {
        req = req + extraHeaders.data[h] + "\r\n"
        h = h + 1
    }
    if text.length(body) > 0 {
        req = req + "Content-Type: " + contentType + "\r\n"
                  + "Content-Length: " + text.length(body) + "\r\n"
    }
    req = req + "\r\n" + body

    return sendHttp(u, req)
}

// Shared transport: write the raw request and parse the raw response.
producer sendHttp(u: Url, req: String) -> Response! {
    let raw = ""
    if u.tls {
        // HTTPS: the runtime does the TLS round-trip in one call.
        raw = xstd_https_fetch(u.host, u.port, req)
        if text.length(raw) == 0 { return err("https request failed (TLS built in? XC_TLS=1)") }
    } else {
        let cr = net.dial(u.host, u.port)
        if isErr(cr) { return err(cr.err) }
        let c = cr.value
        net.sendText(c, req)
        let chunk = net.recvText(c, 8192)
        while text.length(chunk) > 0 {
            raw = raw + chunk
            chunk = net.recvText(c, 8192)
        }
        net.close(c)
    }
    return parseResponse(raw)
}

producer get(url: String) -> Response! { return request("GET", url, "", "") }
producer post(url: String, body: String, contentType: String) -> Response! {
    return request("POST", url, body, contentType)
}
