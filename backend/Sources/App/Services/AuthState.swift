import Vapor
import NIOPosix

/// Server-side auth session. The app pushes its OWN self-rotating cookie jar (from its
/// persistent WKWebView store) via /auth/cookies — that jar is the session. Reading Firefox
/// directly is only a legacy fallback for a client that never pushes (the web clone, or a
/// standalone `swift run` before the mac app attaches). Once a jar exists, Firefox is never read.
actor AuthState {
    private let threadPool: NIOThreadPool
    private let sessionPath: String

    private(set) var connected = false
    private(set) var profile: GoogleOAuth.Profile?
    private(set) var subscriptions: [GoogleOAuth.Subscription] = []

    // App-pushed jar (the real session).
    private var jar: [PushedCookie]?
    private var jarSession: FirefoxSession.Session?

    // Auth health: set when an authenticated browse comes back empty (profile fails AND subs
    // empty). Exposed via /api/account so the client can un-latch + re-push instead of showing
    // a permanently-"signed in" account with silently empty feeds.
    private(set) var authSuspect = false
    private var lastSuspectCheck = Date.distantPast

    // Legacy Firefox re-read cache (fallback path only).
    private var cachedSession: FirefoxSession.Session?
    private var sessionFetchedAt = Date.distantPast
    private var sessionLoad: Task<FirefoxSession.Session?, Never>?
    private let sessionTTL: TimeInterval = 45

    init(threadPool: NIOThreadPool, sessionPath: String) {
        self.threadPool = threadPool
        self.sessionPath = sessionPath
        if let c = SessionJar.load(from: sessionPath) {
            jar = c
            jarSession = SessionJar.session(from: c)
            print("[AuthState] loaded pushed jar: \(c.count) cookies, session=\(jarSession != nil)")
        }
    }

    func setProfile(_ p: GoogleOAuth.Profile) { profile = p }
    func setSubscriptions(_ s: [GoogleOAuth.Subscription]) { subscriptions = s }
    func setConnected(_ b: Bool) { connected = b }

    func signOut() {
        connected = false; profile = nil; subscriptions = []
        jar = nil; jarSession = nil; authSuspect = false
        invalidateSession()
        let path = sessionPath
        Task.detached { try? FileManager.default.removeItem(atPath: path) }
    }

    // MARK: Pushed jar (the session)

    /// Install the app's exported cookie jar. Rebuilds the session once, clears any suspect
    /// flag, and persists to disk off-actor so a backend restart reloads it (no Firefox needed).
    func setJar(_ cookies: [PushedCookie]) {
        jar = cookies
        jarSession = SessionJar.session(from: cookies)
        authSuspect = false
        let path = sessionPath
        Task.detached { SessionJar.save(cookies, to: path) }
    }

    var hasJar: Bool { jar != nil }

    // MARK: Session resolution

    /// The active session: honor MT_SIGNED_OUT, then the pushed jar, then (legacy) Firefox.
    func session() async -> FirefoxSession.Session? {
        if ProcessInfo.processInfo.environment["MT_SIGNED_OUT"] == "1" { return nil }
        if jar != nil { return jarSession }
        // Legacy fallback: no jar ever pushed — re-read Firefox on a 45s TTL.
        if Date().timeIntervalSince(sessionFetchedAt) < sessionTTL { return cachedSession }
        if let inflight = sessionLoad { return await inflight.value }
        let pool = threadPool
        let task = Task { (try? await pool.runIfActive { FirefoxSession.load() }) ?? nil }
        sessionLoad = task
        let s = await task.value
        cachedSession = s; sessionFetchedAt = Date(); sessionLoad = nil
        return s
    }

    func sessionIfConnected() async -> FirefoxSession.Session? {
        guard connected else { return nil }
        return await session()
    }

    /// Used by /auth/connect. With a jar, just return it (already fresh from the app's rotation);
    /// otherwise bypass the legacy cache and re-read Firefox.
    func freshSession() async -> FirefoxSession.Session? {
        if ProcessInfo.processInfo.environment["MT_SIGNED_OUT"] == "1" { return nil }
        if jar != nil { return jarSession }
        cachedSession = nil; sessionFetchedAt = .distantPast
        return await session()
    }

    func invalidateSession() { cachedSession = nil; sessionFetchedAt = .distantPast }

    // MARK: Auth health

    func clearSuspect() { authSuspect = false }

    /// Probe the current session (rate-limited to 60s). If the account identity call fails AND
    /// subscriptions come back empty, the session has decayed → flag it (leaves `connected` as-is;
    /// the client reacts). A working session clears the flag.
    func suspectCheck(client: Client) async {
        guard connected, Date().timeIntervalSince(lastSuspectCheck) > 60 else { return }
        lastSuspectCheck = Date()
        guard let s = await session() else { return }
        async let p = InnerTube.profile(session: s, client: client)
        async let subs = InnerTube.subscriptions(session: s, client: client)
        let (prof, sb) = await (p, subs)
        authSuspect = (prof == nil && sb.isEmpty)
    }
}

extension Application {
    private struct AuthStateKey: StorageKey { typealias Value = AuthState }
    var auth: AuthState {
        get {
            guard let s = storage[AuthStateKey.self] else { fatalError("AuthState not configured") }
            return s
        }
        set { storage[AuthStateKey.self] = newValue }
    }
}
extension Request { var auth: AuthState { application.auth } }
