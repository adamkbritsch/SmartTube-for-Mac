import Foundation
import WebKit

/// Reads the user's YouTube/Google login cookies from Firefox's local store so the player
/// WebView can run SIGNED IN. This is required for forward-seeking: a signed-OUT youtube.com
/// session is SABR-throttled — the initial buffer plays and short seeks work, but jumping to a
/// far unbuffered position never fetches segments (verified: signed-out far-seek fails on bare
/// YouTube; signed-in it succeeds). Same source the backend already uses (FirefoxSession) —
/// nothing leaves the machine. Falls back to [] (signed-out) if there's no Firefox login.
enum FirefoxCookies {
    /// Blocking (file copy + sqlite subprocess) — call off the main thread.
    static func load() -> [HTTPCookie] {
        guard let db = locateDB() else { return [] }
        let tmp = NSTemporaryDirectory() + "mt_wvck-\(UUID().uuidString).sqlite"
        guard copyWithSidecars(db, to: tmp) else { return [] }
        defer { removeWithSidecars(tmp) }
        // char(9) = TAB delimiter; value may itself contain tabs so rejoin the tail.
        guard let out = runSqlite(db: tmp, sql:
            "SELECT host || char(9) || name || char(9) || path || char(9) || isSecure || char(9) || expiry || char(9) || value "
            + "FROM moz_cookies WHERE host LIKE '%youtube.com' OR host LIKE '%.google.com';")
        else { return [] }

        var cookies: [HTTPCookie] = []
        for line in out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 6 else { continue }
            let host = f[0], name = f[1]
            let path = f[2].isEmpty ? "/" : f[2]
            let secure = (f[3] == "1")
            let expiry = Double(f[4]) ?? 0
            let value = f.dropFirst(5).joined(separator: "\t")
            var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: host, .path: path]
            if secure { props[.secure] = "TRUE" }
            if expiry > 0 { props[.expires] = Date(timeIntervalSince1970: expiry) }
            if let c = HTTPCookie(properties: props) { cookies.append(c) }
        }
        return cookies
    }

    /// The Firefox profile whose cookie store has a YouTube login (LOGIN_INFO present).
    private static func locateDB() -> String? {
        let base = NSHomeDirectory() + "/Library/Application Support/Firefox/Profiles"
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        var fallback: String?
        for profile in profiles {
            let db = base + "/" + profile + "/cookies.sqlite"
            guard FileManager.default.fileExists(atPath: db) else { continue }
            let tmp = NSTemporaryDirectory() + "mt_wvprobe-\(UUID().uuidString).sqlite"
            guard copyWithSidecars(db, to: tmp) else { continue }
            let n = runSqlite(db: tmp, sql: "SELECT COUNT(*) FROM moz_cookies WHERE name='LOGIN_INFO' AND host LIKE '%youtube.com';")
            removeWithSidecars(tmp)
            if (Int((n ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 { return db }
            if fallback == nil { fallback = db }
        }
        return fallback
    }

    /// Copy the DB with its -wal/-shm sidecars — fresh session cookies often live only in the
    /// WAL until a checkpoint, so copying the main DB alone reads stale values.
    private static func copyWithSidecars(_ src: String, to dst: String) -> Bool {
        removeWithSidecars(dst)
        guard (try? FileManager.default.copyItem(atPath: src, toPath: dst)) != nil else { return false }
        for ext in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: src + ext) {
            try? FileManager.default.copyItem(atPath: src + ext, toPath: dst + ext)
        }
        return true
    }
    private static func removeWithSidecars(_ path: String) {
        for p in [path, path + "-wal", path + "-shm"] { try? FileManager.default.removeItem(atPath: p) }
    }
    private static func runSqlite(db: String, sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
