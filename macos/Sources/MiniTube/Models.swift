import Foundation

/// Mirrors the backend `/api/settings` shape. Decoding is missing-key tolerant via the
/// `init(from:)` extension below — inline property defaults alone are NOT (synthesized
/// Decodable throws on a missing key), which matters when a freshly built app polls an
/// older still-running backend.
struct Settings: Codable, Equatable {
    var adBlock: Bool
    var sponsorBlock: Bool
    var deArrow: Bool
    var theaterMode: Bool
    var playbackSpeed: Double
    var theme: String
    var maxResolution: Bool = true          // force highest available source resolution
    var enhance: String = "subtle"          // GPU sharpen preset: "off" | "subtle" | "sharper"
    var autoFullscreen: Bool = false        // auto-enter fullscreen when a video starts
    var sbCategories: [String] = Settings.sbAllCategories   // SponsorBlock categories to auto-skip

    /// Canonical SponsorBlock skip categories, in display order.
    static let sbAllCategories = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic"]

    static let `default` = Settings(
        adBlock: true, sponsorBlock: true, deArrow: true,
        theaterMode: false, playbackSpeed: 1.0, theme: "dark",
        maxResolution: true, enhance: "subtle", autoFullscreen: false,
        sbCategories: Settings.sbAllCategories
    )
}

extension Settings {
    // Decode-tolerant: the six original keys are strict; the newer keys fall back to
    // defaults if absent (kept in an EXTENSION so the memberwise init `.default` uses
    // still exists). Guards new-app-vs-old-backend skew during development.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adBlock = try c.decode(Bool.self, forKey: .adBlock)
        sponsorBlock = try c.decode(Bool.self, forKey: .sponsorBlock)
        deArrow = try c.decode(Bool.self, forKey: .deArrow)
        theaterMode = try c.decode(Bool.self, forKey: .theaterMode)
        playbackSpeed = try c.decode(Double.self, forKey: .playbackSpeed)
        theme = try c.decode(String.self, forKey: .theme)
        maxResolution = (try? c.decode(Bool.self, forKey: .maxResolution)) ?? true
        enhance = (try? c.decode(String.self, forKey: .enhance)) ?? "subtle"
        autoFullscreen = (try? c.decode(Bool.self, forKey: .autoFullscreen)) ?? false
        sbCategories = (try? c.decode([String].self, forKey: .sbCategories)) ?? Settings.sbAllCategories
    }
}

/// YouTube ad-strip keys served by the backend (`GET /api/adrules`), derived from uBO's
/// live upstream filter rules. `pruneKeys` are deleted from the parsed player response;
/// `scrubKeys` are renamed to "no_ads" in raw /player response text. Decode-tolerant so a
/// missing/empty set falls back to the built-in triple (ad-blocking never regresses).
struct AdRules: Codable, Equatable {
    var pruneKeys: [String]
    var scrubKeys: [String]

    static let fallback = AdRules(
        pruneKeys: ["adPlacements", "playerAds", "adSlots"],
        scrubKeys: ["adPlacements", "playerAds", "adSlots"]
    )
}

extension AdRules {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let p = (try? c.decode([String].self, forKey: .pruneKeys)) ?? []
        let s = (try? c.decode([String].self, forKey: .scrubKeys)) ?? []
        pruneKeys = p.isEmpty ? AdRules.fallback.pruneKeys : p
        scrubKeys = s.isEmpty ? AdRules.fallback.scrubKeys : s
    }
}

struct VideoListItem: Codable, Identifiable, Hashable {
    let id: String
    let channel: String
    let originalTitle: String
    let originalThumbnail: String
    let deArrowTitle: String?
    let deArrowThumbnail: String?
    let hasSponsorSegments: Bool?   // optional for decode tolerance
    let hasDeArrow: Bool?
    let durationSeconds: Double?
    let viewCountText: String?      // real metadata on the personalized home feed
    let publishedText: String?
    let channelId: String?          // real: tap the channel name to open its page
    let channelAvatar: String?      // real: the uploader's profile picture
    var previewUrl: String? = nil   // real: animated hover preview (an_webp); absent on the home feed
    /// YouTube's own overflow-menu actions for this card. Empty where YouTube offers none
    /// (e.g. search results) — normal, not an error. Decode-tolerant via the init below.
    var feedback: [FeedbackOption] = []
    var playlistId: String? = nil      // set → this item is a PLAYLIST (search results); open /playlist
    var videoCountText: String? = nil  // playlist badge, YouTube's wording ("51 videos")
    var isShort: Bool = false          // vertical Short (a channel's Shorts tab)
    var verified: Bool = false         // channel is YouTube-verified; the badge draws ONLY when true
}

extension VideoListItem {
    /// The item's real youtube.com URL — playlists and videos live at different paths, so every
    /// "Copy link" / "Open in YouTube" / Visionary send goes through this one place.
    var webURL: String {
        if let pid = playlistId { return "https://www.youtube.com/playlist?list=\(pid)" }
        if isShort { return "https://www.youtube.com/shorts/\(id)" }
        return "https://www.youtube.com/watch?v=\(id)"
    }
}

/// One action from a card's 3-dot menu, carrying the token that performs it.
struct FeedbackOption: Codable, Hashable, Identifiable {
    let kind: String        // "notInterested" | "notChannel" | "removeFromHistory"
    let label: String       // YouTube's own wording
    let token: String
    let undoToken: String?
    var id: String { kind + token.prefix(12) }

    /// SF Symbol matching the action's meaning.
    var symbol: String {
        switch kind {
        case "notChannel":        return "person.slash"
        case "removeFromHistory": return "trash"
        default:                  return "hand.thumbsdown"
        }
    }
}

extension VideoListItem {
    // Decode-tolerant: a payload without `feedback` (older backend) must still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        channel = (try? c.decode(String.self, forKey: .channel)) ?? ""
        originalTitle = (try? c.decode(String.self, forKey: .originalTitle)) ?? ""
        originalThumbnail = (try? c.decode(String.self, forKey: .originalThumbnail)) ?? ""
        deArrowTitle = try? c.decode(String.self, forKey: .deArrowTitle)
        deArrowThumbnail = try? c.decode(String.self, forKey: .deArrowThumbnail)
        hasSponsorSegments = try? c.decode(Bool.self, forKey: .hasSponsorSegments)
        hasDeArrow = try? c.decode(Bool.self, forKey: .hasDeArrow)
        durationSeconds = try? c.decode(Double.self, forKey: .durationSeconds)
        viewCountText = try? c.decode(String.self, forKey: .viewCountText)
        publishedText = try? c.decode(String.self, forKey: .publishedText)
        channelId = try? c.decode(String.self, forKey: .channelId)
        channelAvatar = try? c.decode(String.self, forKey: .channelAvatar)
        previewUrl = try? c.decode(String.self, forKey: .previewUrl)
        feedback = (try? c.decode([FeedbackOption].self, forKey: .feedback)) ?? []
        playlistId = try? c.decode(String.self, forKey: .playlistId)
        videoCountText = try? c.decode(String.self, forKey: .videoCountText)
        isShort = (try? c.decode(Bool.self, forKey: .isShort)) ?? false
        verified = (try? c.decode(Bool.self, forKey: .verified)) ?? false
    }
}

struct FeedPageResponse: Codable {
    let videos: [VideoListItem]
    let continuation: String?
    /// Why an empty feed is empty: "signedOut" | "failed" | nil (genuinely empty). Decode-tolerant.
    var unavailable: String? = nil
}

/// A link inside a description: visible text, its REAL destination (YouTube truncates/shortens the
/// display text and hides the true target in the run's endpoint), and the run's range within the
/// flat description string in UTF-16 code units.
struct DescriptionLink: Codable, Equatable, Hashable {
    let text: String
    let url: String
    let start: Int
    let length: Int
}

/// Metadata for a description link's preview card (fetched only when a description is expanded).
struct LinkPreview: Codable, Equatable, Hashable {
    let url: String
    let title: String?
    let description: String?
    let image: String?
    let siteName: String?
    /// Host shown on the card, so the user always sees where a link actually goes.
    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
    var hasContent: Bool { (title?.isEmpty == false) || (image?.isEmpty == false) }
}

struct WatchInfo: Codable, Equatable {
    let videoId: String
    let title: String
    let channel: String
    let channelId: String
    let channelAvatar: String
    let channelVerified: Bool
    let subscribers: String
    let views: String
    let published: String
    let description: String
    let descriptionLinks: [DescriptionLink]
    let likes: String?
    let recommendations: [VideoListItem]
    let commentCount: String
    let comments: [Comment]
    let commentsContinuation: String?
    let subscribed: Bool?          // signed-in user already subscribed (optional for decode tolerance)
    let likeStatus: Int?           // -1 disliked, 0 none, 1 liked

    // Decode-tolerant: one missing/null cosmetic field must not blank the whole
    // watch page (Codable is all-or-nothing otherwise). videoId/title stay strict.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decode(String.self, forKey: .title)
        channel = (try? c.decode(String.self, forKey: .channel)) ?? ""
        channelId = (try? c.decode(String.self, forKey: .channelId)) ?? ""
        channelAvatar = (try? c.decode(String.self, forKey: .channelAvatar)) ?? ""
        channelVerified = (try? c.decode(Bool.self, forKey: .channelVerified)) ?? false
        subscribers = (try? c.decode(String.self, forKey: .subscribers)) ?? ""
        views = (try? c.decode(String.self, forKey: .views)) ?? ""
        published = (try? c.decode(String.self, forKey: .published)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        descriptionLinks = (try? c.decode([DescriptionLink].self, forKey: .descriptionLinks)) ?? []
        likes = try? c.decode(String.self, forKey: .likes)
        recommendations = (try? c.decode([VideoListItem].self, forKey: .recommendations)) ?? []
        commentCount = (try? c.decode(String.self, forKey: .commentCount)) ?? ""
        comments = (try? c.decode([Comment].self, forKey: .comments)) ?? []
        commentsContinuation = try? c.decode(String.self, forKey: .commentsContinuation)
        subscribed = try? c.decode(Bool.self, forKey: .subscribed)
        likeStatus = try? c.decode(Int.self, forKey: .likeStatus)
    }
}

struct ShortItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let thumbnail: String
}

struct AppNotification: Codable, Identifiable, Hashable {
    let text: String
    let time: String
    let thumbnail: String
    let videoId: String?
    // thumbnail folded in so two same-channel notifications with the same relative
    // time ("2 hours ago") can't collide on ForEach identity.
    var id: String { text + "|" + time + "|" + (videoId ?? thumbnail) }
}

struct Playlist: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let thumbnail: String
    let count: String
}

struct ChannelTabInfo: Codable, Equatable, Identifiable {
    let slug: String       // featured | videos | shorts | streams | playlists | podcasts
    let title: String      // YouTube's own label
    let params: String     // pass back to load this tab
    let selected: Bool
    var id: String { params }
}

struct ChannelInfo: Codable, Equatable {
    let channelId: String
    let name: String
    let handle: String
    let subscribers: String
    let avatar: String
    let videos: [VideoListItem]
    let continuation: String?
    let subscribed: Bool?   // signed-in user already subscribed (optional for decode tolerance)
    /// The channel's real tabs, already filtered server-side to ones this app can render.
    /// Decode-tolerant: an older backend sends none and the tab bar simply doesn't appear.
    var tabs: [ChannelTabInfo]? = nil
}

struct Comment: Codable, Equatable, Identifiable {
    let commentId: String?          // real, stable id from InnerTube (optional for decode tolerance)
    let author: String
    let avatar: String
    let text: String
    let published: String
    let likes: String
    var likesLiked: String = ""     // count to show once you've liked it (YouTube ships both)
    let replies: String
    // Vote tokens straight from YouTube's payload; empty when it offered none (e.g. signed out),
    // in which case the buttons are hidden rather than shown inert.
    var likeToken: String = ""
    var unlikeToken: String = ""
    var dislikeToken: String = ""
    var undislikeToken: String = ""
    var likeState: Int = 0          // -1 disliked, 0 neither, 1 liked — the REAL current vote
    var repliesToken: String = ""   // loads this comment's replies; empty when it has none
    var id: String {
        if let c = commentId, !c.isEmpty { return c }
        return author + "|" + published + "|" + text.prefix(24)   // fallback for older payloads
    }

    // Decode-tolerant: one malformed comment must not nuke the whole page of comments.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commentId = try? c.decode(String.self, forKey: .commentId)
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        avatar = (try? c.decode(String.self, forKey: .avatar)) ?? ""
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        published = (try? c.decode(String.self, forKey: .published)) ?? ""
        likes = (try? c.decode(String.self, forKey: .likes)) ?? ""
        likesLiked = (try? c.decode(String.self, forKey: .likesLiked)) ?? ""
        replies = (try? c.decode(String.self, forKey: .replies)) ?? ""
        likeToken = (try? c.decode(String.self, forKey: .likeToken)) ?? ""
        unlikeToken = (try? c.decode(String.self, forKey: .unlikeToken)) ?? ""
        dislikeToken = (try? c.decode(String.self, forKey: .dislikeToken)) ?? ""
        undislikeToken = (try? c.decode(String.self, forKey: .undislikeToken)) ?? ""
        likeState = (try? c.decode(Int.self, forKey: .likeState)) ?? 0
        repliesToken = (try? c.decode(String.self, forKey: .repliesToken)) ?? ""
    }
}

struct SponsorSegment: Codable, Hashable {
    let category: String
    let segment: [Double]
    let actionType: String?
}

struct Account: Codable, Equatable {
    let configured: Bool
    let signedIn: Bool
    let authSuspect: Bool     // backend flagged the session as decayed (feeds empty)
    let profile: Profile?
    let subscriptions: [Subscription]

    init(configured: Bool, signedIn: Bool, authSuspect: Bool = false, profile: Profile?, subscriptions: [Subscription]) {
        self.configured = configured; self.signedIn = signedIn; self.authSuspect = authSuspect
        self.profile = profile; self.subscriptions = subscriptions
    }

    // Decode-tolerant: missing keys must not fail sign-in state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = (try? c.decode(Bool.self, forKey: .configured)) ?? true
        signedIn = try c.decode(Bool.self, forKey: .signedIn)
        authSuspect = (try? c.decode(Bool.self, forKey: .authSuspect)) ?? false
        profile = try? c.decode(Profile.self, forKey: .profile)
        subscriptions = (try? c.decode([Subscription].self, forKey: .subscriptions)) ?? []
    }

    struct Profile: Codable, Equatable {
        let name: String
        let email: String
        let picture: String
    }
    struct Subscription: Codable, Equatable, Identifiable, Hashable {
        let title: String
        let thumbnail: String
        let channelId: String
        var id: String { channelId.isEmpty ? title : channelId }
    }

    static let empty = Account(configured: false, signedIn: false, authSuspect: false, profile: nil, subscriptions: [])
}

/// Sign-in sheet state. status: connecting | no_session | error
/// Sign-in sheet state. status: webLogin (in-app Google login) | webBlocked (Google refused the
/// embedded login → offer Firefox fallback) | connecting | success | no_session | error.
/// The `userCode`/`verificationURL` fields are retained (unused) so the SmartTube-TV OAuth device
/// flow can be added later without a model change. `id` is CONSTANT so status changes update the
/// sheet content in place instead of dismissing + recreating the hosted WebView.
struct DeviceInfo: Codable, Equatable, Identifiable {
    var userCode: String = ""
    var verificationURL: String = ""
    let status: String
    var id: String { "signin" }
    init(_ status: String) { self.status = status }
    init(userCode: String, verificationURL: String, status: String) {
        self.userCode = userCode; self.verificationURL = verificationURL; self.status = status
    }
}

struct ConnectResult: Codable {
    let signedIn: Bool
    let error: String?
    let subscriptionCount: Int?
}

struct VideoDetail: Codable {
    let id: String
    let channel: String
    let originalTitle: String
    let originalThumbnail: String
    let deArrowTitle: String?
    let deArrowThumbnail: String?
    let sponsorSegments: [SponsorSegment]
}
