import Vapor

/// A catalog entry keyed by a real YouTube video ID. Original (clickbait) title,
/// channel and thumbnail come from the seed and are enriched at startup via
/// YouTube oEmbed (no API key required).
struct Video: Content, Sendable {
    let id: String            // real YouTube video ID
    var title: String         // original / "clickbait" title
    var channel: String       // author name
    var thumbnail: String     // original thumbnail URL

    /// Default thumbnail derived from the video ID (used before/if oEmbed fails).
    static func defaultThumbnail(_ id: String) -> String {
        "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
    }
}

/// One community-marked segment from the SponsorBlock API. `segment` is `[start, end]`
/// in seconds.
struct SponsorSegment: Content, Sendable {
    let category: String
    let segment: [Double]
    let actionType: String?
    let videoDuration: Double?   // SponsorBlock reports the real video length

    var start: Double { segment.first ?? 0 }
    var end: Double { segment.count > 1 ? segment[1] : 0 }
}

/// Subset of the DeArrow `/api/branding` response.
struct DeArrowBranding: Content, Sendable {
    struct TitleEntry: Content, Sendable {
        let title: String
        let original: Bool?
        let votes: Int?
        let locked: Bool?
    }
    struct ThumbnailEntry: Content, Sendable {
        let timestamp: Double?
        let original: Bool?
        let votes: Int?
        let locked: Bool?
    }
    let titles: [TitleEntry]
    let thumbnails: [ThumbnailEntry]
}

/// Unified detail response for `GET /api/videos/:id`. Both clients read this and
/// apply the current settings themselves (so a toggle flip is reflected without a
/// re-fetch of video data).
struct VideoDetail: Content, Sendable {
    let id: String
    let channel: String
    let originalTitle: String
    let originalThumbnail: String
    let deArrowTitle: String?
    let deArrowThumbnail: String?
    let sponsorSegments: [SponsorSegment]
}
