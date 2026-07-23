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
        guard let url = URL(string: "\(base)/auth/cookies") else { return false }
        guard let body = try? JSONSerialization.data(withJSONObject: jar) else {
            print("[PlayerSession] push: JSON serialize FAILED (jar=\(jar.count))"); return false
        }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { print("[PlayerSession] push: HTTP \(code) (jar=\(jar.count))"); return false }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (obj["ok"] as? Bool) ?? true
            }
            return true
        } catch {
            // -1004 = backend not up yet during the launch retry; expected, don't log.
            if (error as NSError).code != -1004 { print("[PlayerSession] push: \(error)") }
            return false
        }
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

    /// Reliable async delay. Task.sleep on a main-actor task doesn't resume dependably in this
    /// plain-SwiftPM AppKit executable; DispatchQueue integrates with the run loop and does.
    private func delay(_ seconds: Double) async {
        await withCheckedContinuation { cont in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { cont.resume() }
        }
    }

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
                await delay(0.3)
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
            if await pushToBackend() { print("[PlayerSession] session jar pushed (attempt \(attempt))"); break }
            await delay(1.0)
        }
        startKeepalive()
    }

    /// Sign out: delete the store's cookies (keeping the same store identity so a fresh sign-in
    /// re-seeds it cleanly — avoids the lazy-store staleness of minting a new identifier mid-run).
    func reset() async {
        UserDefaults.standard.set(false, forKey: seededKey)
        let cookies = await allCookies()
        for c in cookies { await deleteCookie(c) }
    }

    // MARK: Keepalive

    /// A session that just sits idle stops rotating and decays. While the app runs and is signed in,
    /// load a light authenticated page (~12 min cadence) so YouTube keeps issuing fresh
    /// __Secure-*PSIDTS, then re-push. Self-guards: signed out, mid-watch (playback already rotates),
    /// or rotated < 60s ago → skip. Reuses the offscreen store-warmup webview.
    func startKeepalive() {
        guard keepaliveTimer == nil else { return }
        warmupWebView?.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        // Run-loop timers, NOT Task.sleep — a nested main-actor Task.sleep doesn't resume reliably in
        // this plain-SwiftPM AppKit executable (Timer/asyncAfter integrate with the run loop and do).
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in   // freshen after launch
            Task { @MainActor in await self?.keepaliveTick() }
        }
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 720, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.keepaliveTick() }
        }
    }
    func stopKeepalive() { keepaliveTimer?.invalidate(); keepaliveTimer = nil }

    private func keepaliveTick() async {
        if ProcessInfo.processInfo.environment["MT_SIGNED_OUT"] == "1" { return }
        guard !watchOpen, Date().timeIntervalSince(lastRotateAt) > 60, await hasAuthCookies(),
              let web = warmupWebView, let url = URL(string: "https://www.youtube.com/account") else { return }
        print("[PlayerSession] keepalive: rotating session (youtube.com/account)")
        web.load(URLRequest(url: url))
        lastRotateAt = Date()
        // Push the rotated jar after the load applies Set-Cookie.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            Task { @MainActor in await PlayerSession.shared.pushToBackend() }
        }
    }
}
