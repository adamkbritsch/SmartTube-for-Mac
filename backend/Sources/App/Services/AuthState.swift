import Vapor
import NIOPosix

/// Server-side auth session for the Firefox-cookie sign-in. Holds the connected
/// flag, the cached profile/subscriptions, and a short-TTL cache of the Firefox
/// session cookies (loaded off the event loop via the app's thread pool).
actor AuthState {
    private let threadPool: NIOThreadPool

    private(set) var connected = false   // Firefox-session (cookie) sign-in
    private(set) var profile: GoogleOAuth.Profile?
    private(set) var subscriptions: [GoogleOAuth.Subscription] = []

    private var cachedSession: FirefoxSession.Session?
    private var sessionFetchedAt = Date.distantPast
    private var sessionLoad: Task<FirefoxSession.Session?, Never>?
    private let sessionTTL: TimeInterval = 45

    init(threadPool: NIOThreadPool) {
        self.threadPool = threadPool
    }

    func setProfile(_ p: GoogleOAuth.Profile) { profile = p }
    func setSubscriptions(_ s: [GoogleOAuth.Subscription]) { subscriptions = s }
    func setConnected(_ b: Bool) { connected = b }

    func signOut() {
        connected = false; profile = nil; subscriptions = []
        invalidateSession()
    }

    // MARK: Firefox session cache

    /// The Firefox session, cached for `sessionTTL`. The blocking cookie-store read
    /// runs on the thread pool; concurrent callers coalesce onto one in-flight load.
    func session() async -> FirefoxSession.Session? {
        if Date().timeIntervalSince(sessionFetchedAt) < sessionTTL { return cachedSession }
        if let inflight = sessionLoad { return await inflight.value }
        let pool = threadPool
        let task = Task { (try? await pool.runIfActive { FirefoxSession.load() }) ?? nil }
        sessionLoad = task
        let s = await task.value
        cachedSession = s; sessionFetchedAt = Date(); sessionLoad = nil
        return s
    }

    /// The session, but only when the user has connected — the guard most
    /// endpoints want.
    func sessionIfConnected() async -> FirefoxSession.Session? {
        guard connected else { return nil }
        return await session()
    }

    /// Bypass the cache (used by /auth/connect so sign-in always re-reads Firefox).
    func freshSession() async -> FirefoxSession.Session? {
        cachedSession = nil; sessionFetchedAt = .distantPast
        return await session()
    }

    func invalidateSession() { cachedSession = nil; sessionFetchedAt = .distantPast }
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
