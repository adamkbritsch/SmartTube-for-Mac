import Vapor

/// Reads the user's existing YouTube login from Firefox's local cookie store — the
/// same idea as `yt-dlp --cookies-from-browser`. Nothing leaves the machine except
/// authenticated calls to youtube.com. No OAuth client / Google Cloud setup needed.
enum FirefoxSession {
    struct Session: Sendable {
        let cookieHeader: String
        let sapisid: String
    }

    /// Blocking (file copy + subprocess). Never call from an event loop — go
    /// through AuthState.session().
    static func load() -> Session? {
        // MT_SIGNED_OUT=1 → force a logged-out session (clean screenshots; matches the WebView).
        if ProcessInfo.processInfo.environment["MT_SIGNED_OUT"] == "1" { return nil }
        guard let db = locateDB() else { return nil }
        let tmp = NSTemporaryDirectory() + "mt_ffck-\(UUID().uuidString).sqlite"
        guard copyWithSidecars(db, to: tmp) else { return nil }
        defer { removeWithSidecars(tmp) }

        guard let out = runSqlite(db: tmp,
            sql: "SELECT host || char(9) || name || char(9) || value FROM moz_cookies WHERE host LIKE '%youtube.com' OR host LIKE '%.google.com';")
        else { return nil }

        // Dedupe by name, PREFERRING the youtube.com-scoped value (the session cookies
        // youtube.com actually validates), matching a working reference implementation.
        var jar: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let host = parts[0], name = parts[1], value = parts.dropFirst(2).joined(separator: "\t")
            if jar[name] == nil || host.contains("youtube") { jar[name] = value }
        }
        guard let sapisid = jar["SAPISID"] ?? jar["__Secure-3PAPISID"] ?? jar["__Secure-1PAPISID"] else {
            print("[FirefoxSession] load: no SAPISID among \(jar.count) cookies → no session")
            return nil
        }
        let sidFam = ["SID", "__Secure-1PSID", "__Secure-3PSID"].filter { jar[$0] != nil }
        print("[FirefoxSession] load: \(jar.count) cookies, SID-family=\(sidFam.count), LOGIN_INFO=\(jar["LOGIN_INFO"] != nil)")
        let header = jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return Session(cookieHeader: header, sapisid: sapisid)
    }

    /// The Firefox profile whose cookie store actually holds the YouTube/Google auth
    /// cookies. Scored by how many of the auth cookies (SAPISID + SID family) it carries,
    /// so an empty or stale sibling profile can never win. (Previously keyed on the
    /// LOGIN_INFO cookie, but YouTube no longer reliably sets it — when it's absent the
    /// old code silently fell back to the FIRST profile on disk, which may be an empty
    /// stale one, producing a logged-OUT session and a non-personalized feed.)
    private static func locateDB() -> String? {
        let base = NSHomeDirectory() + "/Library/Application Support/Firefox/Profiles"
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        var best: (db: String, score: Int)?
        for profile in profiles {
            let db = base + "/" + profile + "/cookies.sqlite"
            guard FileManager.default.fileExists(atPath: db) else { continue }
            let tmp = NSTemporaryDirectory() + "mt_probe-\(UUID().uuidString).sqlite"
            guard copyWithSidecars(db, to: tmp) else { continue }
            let n = runSqlite(db: tmp, sql: "SELECT COUNT(*) FROM moz_cookies WHERE name IN ('SAPISID','__Secure-1PSID','__Secure-3PSID','SID') AND (host LIKE '%youtube.com' OR host LIKE '%.google.com');")
            removeWithSidecars(tmp)
            let score = Int((n ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if score > (best?.score ?? 0) { best = (db, score) }
        }
        if let best { print("[FirefoxSession] selected profile (auth-cookie score \(best.score)): \(best.db)") }
        else { print("[FirefoxSession] no Firefox profile has YouTube auth cookies") }
        return best?.db
    }

    /// Copy the sqlite DB together with its -wal/-shm sidecars. Firefox rotates
    /// session cookies and the fresh values often live only in the WAL until a
    /// checkpoint — copying just the main DB reads STALE cookies and auth fails.
    private static func copyWithSidecars(_ src: String, to dst: String) -> Bool {
        removeWithSidecars(dst)
        guard (try? FileManager.default.copyItem(atPath: src, toPath: dst)) != nil else { return false }
        for ext in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: src + ext) {
            try? FileManager.default.copyItem(atPath: src + ext, toPath: dst + ext)
        }
        return true
    }

    private static func removeWithSidecars(_ path: String) {
        for p in [path, path + "-wal", path + "-shm"] {
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    private static func runSqlite(db: String, sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        // An unread Pipe deadlocks waitUntilExit once stderr exceeds the ~64KB
        // pipe buffer — discard instead.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
