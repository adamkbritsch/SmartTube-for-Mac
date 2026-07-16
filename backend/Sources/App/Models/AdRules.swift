import Vapor

/// YouTube ad-strip key paths, derived from uBlock Origin's live upstream filter
/// rules (the uAssets repo). This is what makes ad-blocking "use the updates": when
/// YouTube changes ad delivery, uBO ships a new `json-prune` rule within hours and the
/// backend re-downloads it — the player's key list updates with no app release.
///
/// `pruneKeys` are leaf keys DELETED from the parsed `ytInitialPlayerResponse` object
/// (the player's `strip(o)` recursion). `scrubKeys` are leaf keys RENAMED to "no_ads"
/// in the raw /player fetch/XHR response text before parse (the player's `scrub(t)`).
/// The two map 1:1 onto uBO's `json-prune` vs `json-prune-fetch/xhr-response` scriptlets.
struct AdRules: Content, Sendable, Equatable {
    var pruneKeys: [String]
    var scrubKeys: [String]
    var matchedRules: Int      // upstream rules that contributed (reporting)
    var sources: [String]
    var updated: Date

    /// The keys the player has always hardcoded — used when the upstream fetch/parse
    /// fails or hasn't happened yet, so ad-blocking never regresses below today's baseline.
    static let fallback = AdRules(
        pruneKeys: ["adPlacements", "playerAds", "adSlots"],
        scrubKeys: ["adPlacements", "playerAds", "adSlots"],
        matchedRules: 0,
        sources: ["builtin-fallback"],
        updated: Date(timeIntervalSince1970: 0)
    )
}
