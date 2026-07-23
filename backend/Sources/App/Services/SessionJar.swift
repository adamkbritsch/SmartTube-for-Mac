import Vapor

/// A YouTube/Google cookie pushed from the macOS app's OWN persistent WKWebView store.
/// The app is the single session owner now: it holds a real browser profile that rotates
/// `__Secure-*PSIDTS` on normal page loads and persists them, then pushes the current jar
/// here. This replaces reading Firefox's cookies (a static snapshot that decayed in days,
/// because every Set-Cookie rotation was discarded and the chain forked with live Firefox).
struct PushedCookie: Content, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String?
    let secure: Bool?
    let expires: Double?     // unix seconds; nil = session cookie
}

enum SessionJar {
    /// Reduce a pushed jar to the same `FirefoxSession.Session` currency InnerTube already
    /// speaks (cookieHeader + sapisid) — so no InnerTube signature changes. Dedupe by name
    /// PREFERRING the youtube.com-scoped value, exactly like `FirefoxSession.load()`.
    static func session(from cookies: [PushedCookie]) -> FirefoxSession.Session? {
        var jar: [String: String] = [:]
        for c in cookies {
            if jar[c.name] == nil || c.domain.contains("youtube") { jar[c.name] = c.value }
        }
        guard let sapisid = jar["SAPISID"] ?? jar["__Secure-3PAPISID"] ?? jar["__Secure-1PAPISID"] else {
            return nil
        }
        let header = jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return FirefoxSession.Session(cookieHeader: header, sapisid: sapisid)
    }

    /// Persisted jar path. NOT the compile-time `#filePath` repo path settings.json/adrules.json
    /// use — this is the install-stable per-user App Support dir the mac side already uses for
    /// backend.pid/backend.log, so the session survives on any machine.
    static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/YouTube/session.json"
    }

    static func load(from path: String) -> [PushedCookie]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode([PushedCookie].self, from: data)
    }

    static func save(_ cookies: [PushedCookie], to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // Auth cookies are sensitive — owner read/write only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
