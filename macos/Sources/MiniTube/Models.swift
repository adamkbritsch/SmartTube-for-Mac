import Foundation

/// Mirrors the backend `/api/settings` shape. Optional keys the backend omits when
/// nil decode fine because the properties are non-optional with server defaults.
struct Settings: Codable, Equatable {
    var adBlock: Bool
    var sponsorBlock: Bool
    var deArrow: Bool
    var theaterMode: Bool
    var playbackSpeed: Double
    var theme: String
    var maxResolution: Bool = true          // force highest available source resolution
    var enhance: String = "subtle"          // GPU sharpen preset: "off" | "subtle" | "sharper"

    static let `default` = Settings(
        adBlock: true, sponsorBlock: true, deArrow: true,
        theaterMode: false, playbackSpeed: 1.0, theme: "dark",
        maxResolution: true, enhance: "subtle"
    )
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
}

struct FeedPageResponse: Codable {
    let videos: [VideoListItem]
    let continuation: String?
}

struct WatchInfo: Codable, Equatable {
    let videoId: String
    let title: String
    let channel: String
    let channelId: String
    let subscribers: String
    let views: String
    let published: String
    let description: String
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
        subscribers = (try? c.decode(String.self, forKey: .subscribers)) ?? ""
        views = (try? c.decode(String.self, forKey: .views)) ?? ""
        published = (try? c.decode(String.self, forKey: .published)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
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

struct ChannelInfo: Codable, Equatable {
    let channelId: String
    let name: String
    let handle: String
    let subscribers: String
    let avatar: String
    let videos: [VideoListItem]
    let continuation: String?
    let subscribed: Bool?   // signed-in user already subscribed (optional for decode tolerance)
}

struct Comment: Codable, Equatable, Identifiable {
    let commentId: String?          // real, stable id from InnerTube (optional for decode tolerance)
    let author: String
    let avatar: String
    let text: String
    let published: String
    let likes: String
    let replies: String
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
        replies = (try? c.decode(String.self, forKey: .replies)) ?? ""
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
    let profile: Profile?
    let subscriptions: [Subscription]

    init(configured: Bool, signedIn: Bool, profile: Profile?, subscriptions: [Subscription]) {
        self.configured = configured; self.signedIn = signedIn
        self.profile = profile; self.subscriptions = subscriptions
    }

    // Decode-tolerant: a missing subscriptions array must not fail sign-in state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = (try? c.decode(Bool.self, forKey: .configured)) ?? true
        signedIn = try c.decode(Bool.self, forKey: .signedIn)
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

    static let empty = Account(configured: false, signedIn: false, profile: nil, subscriptions: [])
}

/// Sign-in sheet state. status: connecting | no_session | error
struct DeviceInfo: Codable, Equatable, Identifiable {
    let userCode: String
    let verificationURL: String
    let status: String
    var id: String { userCode.isEmpty ? status : userCode }
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
