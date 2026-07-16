import Vapor

/// Shared toggle state. The companion Firefox extension is the writer; the web
/// clone and the macOS app read it. Persisted to `settings.json` so it survives
/// restarts and is genuinely shared across all clients.
struct Settings: Content, Sendable, Equatable {
    // Reproduced-extension behaviors
    var adBlock: Bool        // uBlock Origin
    var sponsorBlock: Bool   // SponsorBlock
    var deArrow: Bool        // DeArrow

    // Baked-in native UI features (Improve YouTube ideas)
    var theaterMode: Bool
    var playbackSpeed: Double
    var theme: String        // "dark" | "light"

    // Picture quality (real-YouTube player). NOTE: inline defaults do NOT by themselves
    // make an older settings.json decode-tolerant — synthesized Decodable throws on a
    // missing key regardless. AppState.loadSettings handles that by decoding via
    // SettingsPatch; these defaults are the memberwise-init/.default values.
    var maxResolution: Bool = true  // force the highest available source resolution
    var enhance: String = "subtle"  // GPU detail-sharpen preset: "off" | "subtle" | "sharper"
    var autoFullscreen: Bool = false // auto-enter fullscreen when a video starts playing
    var sbCategories: [String] = Settings.sbAllCategories  // SponsorBlock categories to auto-skip

    /// Canonical SponsorBlock skip categories, in display order.
    static let sbAllCategories = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic"]

    static let `default` = Settings(
        adBlock: true,
        sponsorBlock: true,
        deArrow: true,
        theaterMode: false,
        playbackSpeed: 1.0,
        theme: "dark",
        maxResolution: true,
        enhance: "subtle",
        autoFullscreen: false,
        sbCategories: Settings.sbAllCategories
    )
}

/// Valid values for the `enhance` preset.
let enhancePresets: Set<String> = ["off", "subtle", "sharper"]

/// Partial update payload for `PATCH /api/settings` — every field optional so a
/// client can flip a single toggle without resending the whole object.
struct SettingsPatch: Content, Sendable {
    var adBlock: Bool?
    var sponsorBlock: Bool?
    var deArrow: Bool?
    var theaterMode: Bool?
    var playbackSpeed: Double?
    var theme: String?
    var maxResolution: Bool?
    var enhance: String?
    var autoFullscreen: Bool?
    var sbCategories: [String]?

    func applied(to s: Settings) -> Settings {
        var out = s
        if let v = adBlock { out.adBlock = v }
        if let v = sponsorBlock { out.sponsorBlock = v }
        if let v = deArrow { out.deArrow = v }
        if let v = theaterMode { out.theaterMode = v }
        if let v = playbackSpeed { out.playbackSpeed = max(0.25, min(3.0, v)) }
        if let v = theme, v == "dark" || v == "light" { out.theme = v }
        if let v = maxResolution { out.maxResolution = v }
        if let v = enhance, enhancePresets.contains(v) { out.enhance = v }
        if let v = autoFullscreen { out.autoFullscreen = v }
        // Allowlist to canonical categories in canonical order (drops unknowns/dupes;
        // an empty array is legal — the user turned every category off).
        if let v = sbCategories { out.sbCategories = Settings.sbAllCategories.filter { v.contains($0) } }
        return out
    }
}
