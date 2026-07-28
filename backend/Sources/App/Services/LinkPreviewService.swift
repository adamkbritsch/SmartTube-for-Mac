import Vapor
import NIOCore
import AsyncHTTPClient

/// Gmail-style link previews for description links: fetch the page and pull its OpenGraph/title
/// metadata. Fetched ONLY when the user expands a description, never for videos merely scrolled past.
///
/// SECURITY: this is the only endpoint in the app that fetches a REMOTE-SUPPLIED URL, so it is
/// hardened deliberately. The backend listens on loopback and serves the user's YouTube session at
/// /api/account, which is exactly what an SSRF here could exfiltrate. Guards: http/https only;
/// loopback / private / link-local / metadata hosts rejected; **redirects are NOT auto-followed**
/// (AsyncHTTPClient's default follows up to 5 hops with no per-hop check, which would let a public
/// URL bounce to 127.0.0.1) — each hop is re-validated by hand; short timeout; capped body read.
struct LinkPreview: Content, Sendable, Equatable {
    let url: String          // final resolved URL
    let title: String?
    let description: String?
    let image: String?
    let siteName: String?
    var ok: Bool { title != nil || description != nil || image != nil }

    static func empty(_ url: String) -> LinkPreview {
        LinkPreview(url: url, title: nil, description: nil, image: nil, siteName: nil)
    }
}

enum LinkPreviewService {
    private static let maxBytes = 1024 * 1024     // OG tags live in <head>; never read a whole file
    private static let maxRedirects = 3

    /// A DEDICATED client with redirects DISALLOWED. Vapor's shared `req.client` follows redirects
    /// automatically (verified: a public redirector pointing at 127.0.0.1 was fetched, guard and
    /// all), which would defeat the per-hop validation below — and the shared client's redirect
    /// behavior can't be changed without also affecting InnerTube/EasyList/uAssets fetches. Held
    /// statically for the process lifetime, so it is never deinited without shutdown.
    private static let http = HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: .init(redirectConfiguration: .disallow,
                             timeout: .init(connect: .seconds(5), read: .seconds(6)))
    )

    /// Fetch + parse. Returns an empty preview (not nil) for anything unreachable or blocked, so
    /// the caller can cache the failure and not retry it on every expand.
    static func fetch(url raw: String, client: Client, logger: Logger) async -> LinkPreview {
        var current = raw
        for _ in 0...maxRedirects {
            guard let uri = validated(current) else {
                logger.warning("linkpreview: blocked \(current)")
                return .empty(raw)
            }
            do {
                var req = HTTPClientRequest(url: uri)
                req.headers.add(name: "User-Agent", value: "Mozilla/5.0 (compatible; SmartTubeForMac/1.0; link preview)")
                req.headers.add(name: "Accept", value: "text/html,application/xhtml+xml")
                let res = try await http.execute(req, timeout: .seconds(8))
                // Redirects are NOT auto-followed: re-validate every hop against the guards.
                if (300..<400).contains(Int(res.status.code)),
                   let loc = res.headers.first(name: "location") {
                    current = absolute(loc, base: uri) ?? loc
                    continue
                }
                guard res.status == .ok else { return .empty(current) }
                // Stream and STOP at the cap. `collect(upTo:)` THROWS on overflow, which silently
                // lost previews for any large page (GitHub's HTML is >1MB). OG tags live in <head>,
                // so the first chunk or two is all we need.
                var collected = ByteBuffer()
                for try await chunk in res.body {
                    var c = chunk
                    collected.writeBuffer(&c)
                    if collected.readableBytes >= maxBytes { break }
                }
                let html = collected.readString(length: collected.readableBytes) ?? ""
                return parse(html, url: current)
            } catch {
                logger.warning("linkpreview: \(current): \(error)")
                return .empty(raw)
            }
        }
        return .empty(raw)
    }

    /// http/https only, and never a host that resolves to somewhere private. Returns the URL string
    /// when safe, nil when it must be blocked.
    static func validated(_ s: String) -> String? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = u.host?.lowercased(), !host.isEmpty else { return nil }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return nil }
        if isPrivateAddress(host) { return nil }
        return s
    }

    /// Literal-IP checks. (A DNS name pointing at a private IP isn't resolved here — the practical
    /// threat is a description link using a literal address or a redirect to one, and Vapor's client
    /// doesn't expose the resolved peer for a pre-connect check.)
    static func isPrivateAddress(_ host: String) -> Bool {
        var h = host
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }   // IPv6 literal
        if h == "::1" || h == "::" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") { return true }
        let parts = h.split(separator: ".")
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              parts.allSatisfy({ Int($0) != nil }) else { return false }
        if a == 127 || a == 0 || a == 10 { return true }                    // loopback / this-host / private
        if a == 169 && b == 254 { return true }                             // link-local (cloud metadata)
        if a == 172 && (16...31).contains(b) { return true }                // private
        if a == 192 && b == 168 { return true }                             // private
        return false
    }

    private static func absolute(_ location: String, base: String) -> String? {
        if location.lowercased().hasPrefix("http://") || location.lowercased().hasPrefix("https://") { return location }
        return URL(string: location, relativeTo: URL(string: base))?.absoluteString
    }

    /// Pure + testable: pull OpenGraph tags, falling back to <title>.
    static func parse(_ html: String, url: String) -> LinkPreview {
        func og(_ property: String) -> String? {
            // <meta property="og:title" content="…"> in either attribute order.
            for pattern in ["<meta[^>]+(?:property|name)=[\"']\(property)[\"'][^>]+content=[\"']([^\"']*)[\"']",
                            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:property|name)=[\"']\(property)[\"']"] {
                if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let r = Range(m.range(at: 1), in: html) {
                    let v = decodeEntities(String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines))
                    if !v.isEmpty { return v }
                }
            }
            return nil
        }
        var title = og("og:title") ?? og("twitter:title")
        if title == nil, let re = try? NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: [.caseInsensitive]),
           let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(m.range(at: 1), in: html) {
            let v = decodeEntities(String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines))
            if !v.isEmpty { title = v }
        }
        let image = (og("og:image") ?? og("twitter:image")).flatMap { absolute($0, base: url) }.flatMap { validated($0) }
        return LinkPreview(
            url: url,
            title: title.map { String($0.prefix(200)) },
            description: (og("og:description") ?? og("description") ?? og("twitter:description")).map { String($0.prefix(400)) },
            image: image,
            siteName: og("og:site_name").map { String($0.prefix(80)) }
        )
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        for (e, c) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                       ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: e, with: c)
        }
        return out
    }
}
