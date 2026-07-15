import Vapor

/// The cosmetic hiding selectors we expose to clients, derived from a real,
/// auto-updating upstream filter list. `totalRules` is the size of the parsed
/// source (for reporting), `selectors` is the ad-focused subset clients apply.
struct UBlockRules: Content, Sendable {
    var selectors: [String]
    var totalRules: Int
    var source: String
    var updated: Date

    /// Built-in fallback so ad-hiding still works if the upstream fetch fails or
    /// hasn't happened yet. Includes our own clone's ad-unit class.
    static let fallback = UBlockRules(
        selectors: [
            ".mt-ad-card",
            ".adsbygoogle",
            "#player-ads",
            ".ytp-ad-module",
            "ytd-ad-slot-renderer",
            "ytd-promoted-video-renderer",
            ".video-ads",
        ],
        totalRules: 7,
        source: "builtin-fallback",
        updated: Date(timeIntervalSince1970: 0)
    )
}
