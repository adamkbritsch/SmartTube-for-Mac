import Vapor

/// Item shape for the catalog list. Carries BOTH the original and the DeArrow
/// variants so each client applies the `deArrow` toggle itself — that's what lets
/// flipping the toggle in Firefox change the macOS app without re-fetching.
struct VideoListItem: Content {
    let id: String
    let channel: String
    let originalTitle: String
    let originalThumbnail: String
    let deArrowTitle: String?
    let deArrowThumbnail: String?
    let hasSponsorSegments: Bool   // real: SponsorBlock has segments for this video
    let hasDeArrow: Bool           // real: DeArrow has a community title
    let durationSeconds: Double?   // real: from SponsorBlock's videoDuration
    var viewCountText: String? = nil   // real (home feed): "1.2M views"
    var publishedText: String? = nil   // real (home feed): "3 days ago"
    var channelId: String? = nil       // real (feed/search/recs): tap the channel name to open it
    var channelAvatar: String? = nil   // real: the uploader's profile picture
    var previewUrl: String? = nil      // real: animated hover-preview (an_webp), when YouTube ships one
}

struct FeedPageResponse: Content {
    let videos: [VideoListItem]
    let continuation: String?
}

struct WatchInfo: Content {
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
    let comments: [InnerTube.Comment]
    let commentsContinuation: String?
    let subscribed: Bool
    let likeStatus: Int
}

struct CommentsPage: Content {
    let comments: [InnerTube.Comment]
    let continuation: String?
}

struct Playlist: Content {
    let id: String
    let title: String
    let thumbnail: String
    let count: String
}

struct ChannelResponse: Content {
    let channelId: String
    let name: String
    let handle: String
    let subscribers: String
    let avatar: String
    let videos: [VideoListItem]
    let continuation: String?
    let subscribed: Bool
}

enum VideosController {
    static func list(_ req: Request) async throws -> [VideoListItem] {
        let catalog = await req.state.catalog
        var items: [VideoListItem] = []
        for v in catalog {
            let branding = await req.state.cachedBranding(v.id)   // warmed at startup
            let segments = await req.state.cachedSegments(v.id)
            items.append(VideoListItem(
                id: v.id,
                channel: v.channel,
                originalTitle: v.title,
                originalThumbnail: v.thumbnail,
                deArrowTitle: branding?.title,
                deArrowThumbnail: branding?.thumbnail,
                hasSponsorSegments: (segments?.isEmpty == false),
                hasDeArrow: (branding?.title != nil),
                durationSeconds: segments?.compactMap { $0.videoDuration }.filter { $0 > 0 }.max()
            ))
        }
        return items
    }

    /// Personalized home feed when signed in via the Firefox session; the seeded
    /// demo catalog otherwise.
    static func home(_ req: Request) async throws -> FeedPageResponse {
        guard let session = await req.auth.sessionIfConnected() else {
            return FeedPageResponse(videos: try await list(req), continuation: nil)
        }
        let client = req.client
        let page = await req.state.feed("home") {
            await InnerTube.homeFeed(session: session, client: client)
        }
        guard !page.videos.isEmpty else {
            // Signed in but the personalized home came back empty → the session may have decayed.
            // Probe it (rate-limited) so /api/account can report authSuspect and the client re-pushes.
            Task { await req.auth.suspectCheck(client: client) }
            return FeedPageResponse(videos: try await list(req), continuation: nil)
        }
        return FeedPageResponse(videos: page.videos.map(listItem(from:)), continuation: page.continuation)
    }

    /// The subscriptions feed: newest uploads from subscribed channels, chronological.
    /// Continuation pages flow through the shared /api/feed/more (browse continuation).
    static func subscriptionsFeed(_ req: Request) async throws -> FeedPageResponse {
        guard let session = await req.auth.sessionIfConnected() else {
            return FeedPageResponse(videos: [], continuation: nil)
        }
        let page = await InnerTube.subscriptionsFeed(session: session, client: req.client)
        return FeedPageResponse(videos: page.videos.map(listItem(from:)), continuation: page.continuation)
    }

    /// Next page of the feed for continuous scroll.
    static func more(_ req: Request) async throws -> FeedPageResponse {
        struct Body: Content { let continuation: String }
        let token = try req.content.decode(Body.self).continuation
        let page = await InnerTube.browseContinuation(token: token, session: await req.auth.sessionIfConnected(), client: req.client)
        return FeedPageResponse(videos: page.videos.map(listItem(from:)), continuation: page.continuation)
    }

    /// YouTube search results (page 1).
    static func search(_ req: Request) async throws -> FeedPageResponse {
        let query = (try? req.query.get(String.self, at: "q")) ?? ""
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return FeedPageResponse(videos: [], continuation: nil)
        }
        let page = await InnerTube.search(query: query, session: await req.auth.sessionIfConnected(), client: req.client)
        return FeedPageResponse(videos: page.videos.map(listItem(from:)), continuation: page.continuation)
    }

    /// Next page of search results.
    static func searchMore(_ req: Request) async throws -> FeedPageResponse {
        struct Body: Content { let continuation: String }
        let token = try req.content.decode(Body.self).continuation
        let page = await InnerTube.searchContinuation(token: token, session: await req.auth.sessionIfConnected(), client: req.client)
        return FeedPageResponse(videos: page.videos.map(listItem(from:)), continuation: page.continuation)
    }

    /// Full watch page: real title/channel/subs/views/description + recommendations.
    static func watch(_ req: Request) async throws -> WatchInfo {
        let id = try req.parameters.require("id")
        let session = await req.auth.sessionIfConnected()   // personalized recs + identity if signed in; still works signed out
        guard let m = await InnerTube.watchInfo(videoId: id, session: session, client: req.client) else {
            throw Abort(.notFound, reason: "No watch data for \(id)")
        }
        return WatchInfo(
            videoId: id, title: m.title, channel: m.channel, channelId: m.channelId,
            subscribers: m.subscribers, views: m.views, published: m.published,
            description: m.description, likes: m.likes,
            recommendations: m.recommendations.map(listItem(from:)),
            commentCount: m.commentCount, comments: m.comments,
            commentsContinuation: m.commentsContinuation,
            subscribed: m.subscribed, likeStatus: m.likeStatus
        )
    }

    struct ActionResult: Content { let ok: Bool }

    /// Subscribe / unsubscribe from a channel on the signed-in account.
    static func subscribe(_ req: Request) async throws -> ActionResult {
        struct Body: Content { let channelId: String; let subscribe: Bool }
        let b = try req.content.decode(Body.self)
        guard let session = await req.auth.sessionIfConnected(), !b.channelId.isEmpty else {
            return ActionResult(ok: false)
        }
        let ok = await InnerTube.setSubscription(channelId: b.channelId, subscribe: b.subscribe, session: session, client: req.client)
        return ActionResult(ok: ok)
    }

    /// Records a video in the signed-in account's YouTube watch history (fires YouTube's
    /// own videostats playback ping). Fire-and-forget from the client once the video has
    /// genuinely been watched; a signed-out backend is a silent no-op.
    static func markWatched(_ req: Request) async throws -> ActionResult {
        struct Body: Content { let videoId: String }
        let b = try req.content.decode(Body.self)
        // Canonical 11-char YouTube id only (keeps it out of headers/URLs if malformed).
        let validId = b.videoId.count == 11 && b.videoId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard let session = await req.auth.sessionIfConnected(), validId else {
            return ActionResult(ok: false)
        }
        let ok = await InnerTube.markWatched(videoId: b.videoId, session: session, client: req.application.client)
        return ActionResult(ok: ok)
    }

    /// Like / dislike / clear the like on a video for the signed-in account.
    static func like(_ req: Request) async throws -> ActionResult {
        struct Body: Content { let videoId: String; let state: String }   // "like" | "dislike" | "none"
        let b = try req.content.decode(Body.self)
        guard let session = await req.auth.sessionIfConnected(), !b.videoId.isEmpty else {
            return ActionResult(ok: false)
        }
        let ok = await InnerTube.setLike(videoId: b.videoId, state: b.state, session: session, client: req.client)
        return ActionResult(ok: ok)
    }

    /// Curated HDR-showcase categories. The user's own feed channels rarely publish true HDR
    /// (tech/news/comedy skew SDR — even MKBHD/LTT probe as Rec709), so an HDR shelf built purely
    /// from their channels comes up empty. These seeds pull reference-grade HDR (nature, cinema,
    /// travel, gaming) that actually looks stunning on an HDR display, and several overlap the
    /// user's tech taste (Digital Foundry, LTT surface under "HDR gaming"/"HDR tech").
    static let hdrShowcaseSeeds = [
        "4K HDR", "HDR nature", "HDR cinematic", "Dolby Vision 4K", "HDR gaming", "HDR travel",
    ]

    /// The HDR shelf. Every result comes through YouTube's own "HDR" search filter
    /// (`InnerTube.hdrSearchParams`), so it's HDR-tagged with no per-video probing. Seeds =
    /// curated HDR-showcase categories (quality + guaranteed fill) blended with the caller's
    /// feed channel NAMES (light personalization). Results are round-robin interleaved — the top
    /// HDR pick from each seed leads — then deduped and capped to 2 per channel so no single
    /// creator floods the shelf.
    static func hdr(_ req: Request) async throws -> FeedPageResponse {
        struct Body: Content { let queries: [String] }
        var seenQuery = Set<String>()
        // Showcase seeds first (they set the quality bar and guarantee fill), then feed channels.
        let seeds = (hdrShowcaseSeeds + (try req.content.decode(Body.self).queries))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenQuery.insert($0.lowercased()).inserted }
            .prefix(hdrShowcaseSeeds.count + 8)
        let session = await req.auth.sessionIfConnected()
        let client = req.application.client

        // One HDR-filtered search per seed (parallel). Tag each result set with its seed index
        // so we can reassemble in seed order regardless of completion order.
        let perSeed: [(Int, [InnerTube.FeedVideo])] = await withTaskGroup(of: (Int, [InnerTube.FeedVideo]).self) { group in
            for (idx, q) in seeds.enumerated() {
                group.addTask {
                    let page = await InnerTube.search(query: q, session: session, client: client,
                                                      params: InnerTube.hdrSearchParams)
                    return (idx, Array(page.videos.prefix(8)))
                }
            }
            var out: [(Int, [InnerTube.FeedVideo])] = []
            for await r in group { out.append(r) }
            return out
        }
        let bySeed = perSeed.sorted { $0.0 < $1.0 }.map { $0.1 }

        // Round-robin interleave: rank 0 from every seed (best HDR pick from each category/channel),
        // then rank 1, etc. Dedup videos; cap each result-channel to 2 to keep the shelf varied.
        var seenVideo = Set<String>()
        var perChannelCount: [String: Int] = [:]
        var ordered: [InnerTube.FeedVideo] = []
        let maxRank = bySeed.map(\.count).max() ?? 0
        outer: for rank in 0..<maxRank {
            for results in bySeed where rank < results.count {
                let fv = results[rank]
                guard seenVideo.insert(fv.id).inserted else { continue }
                let chKey = (fv.channelId ?? fv.channel).lowercased()
                let n = perChannelCount[chKey, default: 0]
                if n >= 2 { continue }
                perChannelCount[chKey] = n + 1
                ordered.append(fv)
                if ordered.count >= 48 { break outer }
            }
        }
        return FeedPageResponse(videos: ordered.map(listItem(from:)), continuation: nil)
    }

    /// Next page of comments (continuous scroll).
    static func moreComments(_ req: Request) async throws -> CommentsPage {
        struct Body: Content { let continuation: String }
        let token = try req.content.decode(Body.self).continuation
        let r = await InnerTube.moreComments(token: token, session: await req.auth.sessionIfConnected(), client: req.client)
        return CommentsPage(comments: r.comments, continuation: r.continuation)
    }

    /// A channel's page: header (name/@handle/subs/avatar) + its uploads (Videos tab)
    /// with a continuation token so the grid scrolls via /api/feed/more.
    static func channel(_ req: Request) async throws -> ChannelResponse {
        let id = try req.parameters.require("id")
        guard let ch = await InnerTube.channel(channelId: id, session: await req.auth.sessionIfConnected(), client: req.client) else {
            throw Abort(.notFound, reason: "No channel data for \(id)")
        }
        return ChannelResponse(
            channelId: id, name: ch.name, handle: ch.handle,
            subscribers: ch.subscribers, avatar: ch.avatar,
            videos: ch.videos.map(listItem(from:)), continuation: ch.continuation,
            subscribed: ch.subscribed
        )
    }

    /// Watch history (FEhistory).
    static func history(_ req: Request) async throws -> FeedPageResponse {
        guard let session = await req.auth.sessionIfConnected() else {
            return FeedPageResponse(videos: [], continuation: nil)
        }
        let page = await InnerTube.browseFeed(browseId: "FEhistory", session: session, client: req.client)
        return FeedPageResponse(videos: page.videos.map(listItem(from:)), continuation: page.continuation)
    }

    /// The user's saved playlists (cards → tap opens playlist detail).
    static func playlists(_ req: Request) async throws -> [Playlist] {
        guard let session = await req.auth.sessionIfConnected() else { return [] }
        return (await InnerTube.playlists(session: session, client: req.client))
            .map { Playlist(id: $0.id, title: $0.title, thumbnail: $0.thumbnail, count: $0.count) }
    }

    /// A playlist's videos (VL<id>). id = WL (Watch Later), LL (Liked), or PL… .
    static func playlist(_ req: Request) async throws -> FeedPageResponse {
        let id = try req.parameters.require("id")
        guard let session = await req.auth.sessionIfConnected() else {
            return FeedPageResponse(videos: [], continuation: nil)
        }
        let page = await InnerTube.browseFeed(browseId: "VL" + id, session: session, client: req.client)
        return FeedPageResponse(videos: page.videos.map(listItem(from:)), continuation: page.continuation)
    }

    struct MeResponse: Content { let channelId: String }

    /// The signed-in user's own channel id (for the "Your channel" / "Your videos" rows).
    static func me(_ req: Request) async throws -> MeResponse {
        guard let session = await req.auth.sessionIfConnected(),
              let id = await InnerTube.userChannelId(session: session, client: req.client) else {
            throw Abort(.notFound, reason: "No signed-in channel")
        }
        return MeResponse(channelId: id)
    }

    /// Shorts feed (home-feed shorts).
    static func shorts(_ req: Request) async throws -> [InnerTube.ShortItem] {
        let session = await req.auth.sessionIfConnected()
        return await InnerTube.shorts(session: session, client: req.client)
    }

    /// The notifications inbox (bell).
    static func notifications(_ req: Request) async throws -> [InnerTube.NotificationItem] {
        guard let session = await req.auth.sessionIfConnected() else { return [] }
        return await InnerTube.notifications(session: session, client: req.client)
    }

    static func listItem(from fv: InnerTube.FeedVideo) -> VideoListItem {
        VideoListItem(
            id: fv.id, channel: fv.channel, originalTitle: fv.title, originalThumbnail: fv.thumbnail,
            deArrowTitle: nil, deArrowThumbnail: nil,
            hasSponsorSegments: false, hasDeArrow: false,
            durationSeconds: fv.durationSeconds,
            viewCountText: fv.views, publishedText: fv.published,
            channelId: fv.channelId, channelAvatar: fv.channelAvatar,
            previewUrl: fv.previewUrl
        )
    }

    static func detail(_ req: Request) async throws -> VideoDetail {
        let id = try req.parameters.require("id")
        guard let video = await req.state.find(id) else {
            throw Abort(.notFound, reason: "Unknown video \(id)")
        }
        async let segs = segments(id, req)
        async let brand = branding(id, req)
        let (segments, branding) = await (segs, brand)
        return VideoDetail(
            id: video.id,
            channel: video.channel,
            originalTitle: video.title,
            originalThumbnail: video.thumbnail,
            deArrowTitle: branding.title,
            deArrowThumbnail: branding.thumbnail,
            sponsorSegments: segments
        )
    }

    // MARK: cache-or-fetch helpers (also used by startup warming)

    static func segments(_ id: String, _ req: Request) async -> [SponsorSegment] {
        if let cached = await req.state.cachedSegments(id) { return cached }
        let fresh = await SponsorBlockClient.fetch(videoID: id, client: req.client, logger: req.logger)
        await req.state.storeSegments(fresh, id)
        return fresh
    }

    static func branding(_ id: String, _ req: Request) async -> DeArrowClient.Resolved {
        if let cached = await req.state.cachedBranding(id) { return cached }
        let fresh = await DeArrowClient.fetch(videoID: id, client: req.client, logger: req.logger)
        await req.state.storeBranding(fresh, id)
        return fresh
    }
}
