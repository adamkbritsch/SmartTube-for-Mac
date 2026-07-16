import Vapor

/// Single source of truth shared by every client. An actor so concurrent requests
/// (web clone, macOS app, companion extension) mutate it safely.
actor AppState {
    private(set) var settings: Settings
    private(set) var catalog: [Video]
    private(set) var ublock: UBlockRules
    private(set) var adRules: AdRules

    private let settingsPath: String
    private let adRulesPath: String
    private let ttl: TimeInterval = 10 * 60   // short cache: 10 min, not a snapshot

    private var sbCache: [String: (Date, [SponsorSegment])] = [:]
    private var brandingCache: [String: (Date, DeArrowClient.Resolved)] = [:]

    private var feedCache: [String: (Date, InnerTube.FeedPage)] = [:]
    private var feedInflight: [String: Task<InnerTube.FeedPage, Never>] = [:]
    private let feedTTL: TimeInterval = 45

    init(seed: [Video], settingsPath: String, adRulesPath: String) {
        self.catalog = seed
        self.settingsPath = settingsPath
        self.adRulesPath = adRulesPath
        self.ublock = .fallback
        self.settings = AppState.loadSettings(path: settingsPath) ?? .default
        self.adRules = AppState.loadAdRules(path: adRulesPath) ?? .fallback
    }

    // MARK: Settings

    func patch(_ patch: SettingsPatch) -> Settings {
        settings = patch.applied(to: settings)
        AppState.saveSettings(settings, path: settingsPath)
        return settings
    }

    private static func loadSettings(path: String) -> Settings? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // Decode as a PATCH (every field optional) and merge onto .default, so a
        // settings.json written by an OLDER build — missing any newer key — decodes
        // cleanly instead of THROWING and silently resetting ALL settings. (Swift's
        // synthesized Decodable throws on a missing key even when the property has an
        // inline default, so `decode(Settings.self)` is not actually missing-tolerant.)
        guard let patch = try? JSONDecoder().decode(SettingsPatch.self, from: data) else { return nil }
        return patch.applied(to: .default)
    }

    private static func saveSettings(_ settings: Settings, path: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func loadAdRules(path: String) -> AdRules? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(AdRules.self, from: data)
    }

    private static func saveAdRules(_ rules: AdRules, path: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]   // default date strategy → matches loadAdRules
        if let data = try? enc.encode(rules) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    // MARK: Catalog

    func setCatalog(_ videos: [Video]) { catalog = videos }
    func find(_ id: String) -> Video? { catalog.first { $0.id == id } }

    // MARK: SponsorBlock cache

    func cachedSegments(_ id: String) -> [SponsorSegment]? {
        guard let (date, segs) = sbCache[id], Date().timeIntervalSince(date) < ttl else { return nil }
        return segs
    }
    func storeSegments(_ segs: [SponsorSegment], _ id: String) { sbCache[id] = (Date(), segs) }

    // MARK: DeArrow cache

    func cachedBranding(_ id: String) -> DeArrowClient.Resolved? {
        guard let (date, b) = brandingCache[id], Date().timeIntervalSince(date) < ttl else { return nil }
        return b
    }
    func storeBranding(_ b: DeArrowClient.Resolved, _ id: String) { brandingCache[id] = (Date(), b) }

    // MARK: Feed cache (short TTL; empty pages are never cached)

    /// Cache-or-fetch for feed pages. Concurrent requests for the same key
    /// coalesce onto one in-flight fetch (mirrors the sbCache pattern).
    func feed(_ key: String, fetch: @escaping @Sendable () async -> InnerTube.FeedPage) async -> InnerTube.FeedPage {
        if let (date, p) = feedCache[key], Date().timeIntervalSince(date) < feedTTL { return p }
        if let t = feedInflight[key] { return await t.value }
        let t = Task { await fetch() }
        feedInflight[key] = t
        let page = await t.value
        if !page.videos.isEmpty { feedCache[key] = (Date(), page) }
        feedInflight[key] = nil
        return page
    }
    func clearFeedCache() { feedCache = [:] }

    // MARK: uBlock rules

    func setUBlock(_ rules: UBlockRules) { ublock = rules }

    // MARK: Ad-strip rules (uBO json-prune keys; persisted so a restart serves last-good)

    func setAdRules(_ rules: AdRules) {
        adRules = rules
        AppState.saveAdRules(rules, path: adRulesPath)
    }
}

/// Attaches the shared `AppState` to the Vapor `Application`.
extension Application {
    private struct AppStateKey: StorageKey { typealias Value = AppState }
    var state: AppState {
        get {
            guard let s = storage[AppStateKey.self] else { fatalError("AppState not configured") }
            return s
        }
        set { storage[AppStateKey.self] = newValue }
    }
}

extension Request {
    var state: AppState { application.state }
}
