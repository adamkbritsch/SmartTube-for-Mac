import Foundation
import WebKit

/// The app's OWN YouTube session — a persistent WKWebView profile that seeds once, then
/// rotates and persists its own cookies on normal page loads (like a real browser). This
/// replaces "copy Firefox's cookies and replay a static snapshot," which discarded every
/// ~10-minute Set-Cookie rotation and decayed in days. The player, the sign-in sheet, and the
/// keepalive webview all share THIS store, so playback keeps the session fresh; the backend
/// consumes the exported jar (POST /auth/cookies) instead of reading Firefox.
///
/// Horizon: once Google enforces Device Bound Session Credentials (DBSC) on macOS, a copied
/// cookie set can't rotate forward regardless of how cleanly it's seeded. The DBSC-resistant
/// plan-B is the SmartTube-TV OAuth device flow (device isn't cookie-bound) — not implemented;
/// the DeviceInfo.userCode/verificationURL fields are retained so it can be added later.
@MainActor
final class PlayerSession {
    static let shared = PlayerSession()

    private let base = "http://127.0.0.1:8080"
    private let uuidKey = "MTPlayerStoreUUID"
    private let seededKey = "MTSeeded"

    /// True while a watch page is open — the keepalive stands down (playback already rotates).
    var watchOpen = false
    private var lastRotateAt = Date.distantPast
    private var keepaliveTimer: Timer?
    private var keepaliveWebView: WKWebView?

    /// The persistent, self-rotating store. Stable identifier so it survives relaunch.
    /// MT_SIGNED_OUT=1 → a throwaway non-persistent store (clean signed-out screenshots).
    lazy var store: WKWebsiteDataStore = {
        if ProcessInfo.processInfo.environment["MT_SIGNED_OUT"] == "1" {
            return .nonPersistent()
        }
        return WKWebsiteDataStore(forIdentifier: storeUUID())
    }()

    private func storeUUID() -> UUID {
        if let s = UserDefaults.standard.string(forKey: uuidKey), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: uuidKey)
        return u
    }

    // MARK: Cookie export → backend

    // WKHTTPCookieStore completion-handler APIs wrapped as async (portable across SDK versions).
    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            store.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }
    private func setCookie(_ c: HTTPCookie) async {
        await withCheckedContinuation { cont in store.httpCookieStore.setCookie(c) { cont.resume() } }
    }
    private func deleteCookie(_ c: HTTPCookie) async {
        await withCheckedContinuation { cont in store.httpCookieStore.delete(c) { cont.resume() } }
    }

    /// The youtube/google cookies currently in the store, as the backend's jar shape.
    func exportCookies() async -> [[String: Any]] {
        if ProcessInfo.processInfo.environment["MT_SIGNED_OUT"] == "1" { return [] }
        let all = await allCookies()
        return all.filter { $0.domain.contains("youtube.com") || $0.domain.contains("google.com") }
            .map { c in
                var d: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain,
                                        "path": c.path, "secure": c.isSecure]
                if let e = c.expiresDate { d["expires"] = e.timeIntervalSince1970 }
                return d
            }
    }

    /// POST the current jar to the backend. Returns true if the backend accepted it (used by the
    /// launch retry, since the backend spawns asynchronously).
    @discardableResult
    func pushToBackend() async -> Bool {
        let jar = await exportCookies()
        guard let url = URL(string: "\(base)/auth/cookies"),
              let body = try? JSONSerialization.data(withJSONObject: jar) else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
        lastRotateAt = Date()
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (obj["ok"] as? Bool) ?? true
        }
        return true
    }

    /// True if the store already holds the auth cookies needed for a signed-in session.
    func hasAuthCookies() async -> Bool {
        let all = await allCookies()
        let names = Set(all.map(\.name))
        let hasSapisid = names.contains("SAPISID") || names.contains("__Secure-3PAPISID") || names.contains("__Secure-1PAPISID")
        let hasSID = names.contains("SID") || names.contains("__Secure-1PSID") || names.contains("__Secure-3PSID")
        return hasSapisid && hasSID
    }

    // MARK: Seeding (one-time, fallback only)

    /// One-time seed from Firefox into the persistent store (migration + the sign-in fallback).
    /// After this the store self-rotates; Firefox is never read again.
    func seedFromFirefox() async {
        let cookies: [HTTPCookie] = await Task.detached { FirefoxCookies.load() }.value
        guard !cookies.isEmpty else { return }
        for c in cookies { await setCookie(c) }
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    // MARK: Lifecycle

    /// Called once at launch. Migrates an existing Firefox login into the persistent store (only
    /// if the store has no session yet), pushes the jar, and starts the keepalive.
    private var warmupWebView: WKWebView?

    func bootstrap() async {
        _ = store   // materialize
        // A persistent WKWebsiteDataStore loads its cookies from disk ASYNCHRONOUSLY; getAllCookies
        // right after construction can return empty before that finishes (WebKit cold-start race).
        // Binding a WKWebView spins up the store's network process, then poll until cookies appear.
        if warmupWebView == nil {
            let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = store
            warmupWebView = WKWebView(frame: .zero, configuration: cfg)
        }
        var had = await hasAuthCookies()
        if !had {
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if await hasAuthCookies() { had = true; break }
            }
        }
        if ProcessInfo.processInfo.environment["MT_SIGNED_OUT"] != "1", !had {
            await seedFromFirefox()   // no-op if Firefox has no login
        }
        let now = await hasAuthCookies()
        print("[PlayerSession] bootstrap: storeHadAuth=\(had) afterSeed=\(now)")
        // Retry the push until the backend (spawned async at launch) accepts it.
        for attempt in 0..<15 {
            if await pushToBackend() { print("[PlayerSession] jar pushed (attempt \(attempt))"); break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        startKeepalive()
    }

    /// Sign out: tear down the keepalive, drop the persistent profile, mint a fresh identifier so
    /// the next sign-in starts clean.
    func reset() async {
        stopKeepalive()
        UserDefaults.standard.set(false, forKey: seededKey)
        let old = storeUUID()
        // Best-effort: clear cookies first (works even if a webview still holds the store), then
        // remove the whole profile.
        let cookies = await allCookies()
        for c in cookies { await deleteCookie(c) }
        UserDefaults.standard.set(UUID().uuidString, forKey: uuidKey)   // next store = new identity
        try? await WKWebsiteDataStore.remove(forIdentifier: old)
    }

    // MARK: Keepalive (Part 4) — wired below

    func startKeepalive() { /* implemented in Part 4 */ }
    func stopKeepalive() { keepaliveTimer?.invalidate(); keepaliveTimer = nil; keepaliveWebView = nil }
}
