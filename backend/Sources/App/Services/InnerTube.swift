import Vapor
import Crypto

/// Calls YouTube's internal InnerTube API using the Firefox session (SAPISIDHASH
/// auth), to fetch the signed-in user's channel (identity) and subscriptions.
enum InnerTube {
    static let key = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"   // public WEB InnerTube key
    static let clientVersion = "2.20240402.00.00"
    static let origin = "https://www.youtube.com"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:128.0) Gecko/20100101 Firefox/128.0"

    private static func authHeader(sapisid: String) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(now) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(now)_\(hex)"
    }

    private static func call(path: String, body: [String: Any], session: FirefoxSession.Session?, client: Client) async -> Any? {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let url = "https://www.youtube.com/youtubei/v1/\(path)?key=\(key)&prettyPrint=false"
        do {
            let res = try await client.post(URI(string: url), beforeSend: { req in
                req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
                req.headers.replaceOrAdd(name: "Accept-Encoding", value: "identity")   // no gzip: we parse raw JSON
                if let session {   // authenticated (personalized) when we have the Firefox session
                    req.headers.replaceOrAdd(name: "Cookie", value: session.cookieHeader)
                    req.headers.replaceOrAdd(name: "Authorization", value: authHeader(sapisid: session.sapisid))
                }
                req.headers.replaceOrAdd(name: "Origin", value: origin)
                req.headers.replaceOrAdd(name: "X-Goog-AuthUser", value: "0")
                req.headers.replaceOrAdd(name: "User-Agent", value: userAgent)
                req.body = ByteBuffer(data: bodyData)
            })
            guard res.status == .ok, var buf = res.body else {
                print("[InnerTube] \(path) → HTTP \(res.status.code), body \(res.body?.readableBytes ?? 0) bytes")
                return nil
            }
            let data = buf.readData(length: buf.readableBytes) ?? Data()
            return try? JSONSerialization.jsonObject(with: data)
        } catch {
            print("[InnerTube] \(path) transport error: \(error)")
            return nil
        }
    }

    private static func context() -> [String: Any] {
        ["context": ["client": ["clientName": "WEB", "clientVersion": clientVersion, "hl": "en", "gl": "US"]]]
    }

    // MARK: Subscriptions (the /feed/channels page → channel renderers)

    static func subscriptions(session: FirefoxSession.Session, client: Client) async -> [GoogleOAuth.Subscription] {
        var body = context(); body["browseId"] = "FEchannels"
        guard let json = await call(path: "browse", body: body, session: session, client: client) else { return [] }
        var acc: [String: GoogleOAuth.Subscription] = [:]
        walkChannels(json, into: &acc)
        return acc.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func walkChannels(_ node: Any, into acc: inout [String: GoogleOAuth.Subscription]) {
        if let dict = node as? [String: Any] {
            if let cid = dict["channelId"] as? String, let title = text(dict["title"]), !title.isEmpty {
                acc[cid] = GoogleOAuth.Subscription(title: title, thumbnail: thumb(dict["thumbnail"]), channelId: cid)
            }
            for value in dict.values { walkChannels(value, into: &acc) }
        } else if let arr = node as? [Any] {
            for value in arr { walkChannels(value, into: &acc) }
        }
    }

    // MARK: Personalized home feed (FEwhat_to_watch → video renderers)

    struct FeedVideo: Sendable {
        let id: String
        let title: String
        let channel: String
        let channelId: String?
        let channelAvatar: String
        let thumbnail: String
        let views: String?
        let published: String?
        let durationSeconds: Double?
    }

    struct FeedPage: Sendable {
        let videos: [FeedVideo]
        let continuation: String?
    }

    static func homeFeed(session: FirefoxSession.Session, client: Client) async -> FeedPage {
        var body = context(); body["browseId"] = "FEwhat_to_watch"
        guard let json = await call(path: "browse", body: body, session: session, client: client) else {
            return FeedPage(videos: [], continuation: nil)
        }
        return page(from: json)
    }

    /// Any video-list browse page → FeedPage: history (FEhistory), liked (VLLL),
    /// watch later (VLWL), a playlist (VL<id>). walkVideos handles lockupViewModel +
    /// videoRenderer + playlistVideoRenderer, so all of these parse the same way.
    static func browseFeed(browseId: String, session: FirefoxSession.Session?, client: Client) async -> FeedPage {
        var body = context(); body["browseId"] = browseId
        guard let json = await call(path: "browse", body: body, session: session, client: client) else {
            return FeedPage(videos: [], continuation: nil)
        }
        return page(from: json)
    }

    struct PlaylistItem: Sendable {
        let id: String
        let title: String
        let thumbnail: String
        let count: String
    }

    /// The user's saved playlists (FEplaylist_aggregation → PLAYLIST/PODCAST lockups).
    static func playlists(session: FirefoxSession.Session?, client: Client) async -> [PlaylistItem] {
        var body = context(); body["browseId"] = "FEplaylist_aggregation"
        guard let json = await call(path: "browse", body: body, session: session, client: client) else { return [] }
        var acc: [PlaylistItem] = []
        var seen = Set<String>()
        walkPlaylistLockups(json, into: &acc, seen: &seen)
        return acc
    }

    private static func walkPlaylistLockups(_ node: Any, into acc: inout [PlaylistItem], seen: inout Set<String>) {
        if let dict = node as? [String: Any] {
            if let lvm = dict["lockupViewModel"] as? [String: Any],
               let id = lvm["contentId"] as? String,
               let ctype = lvm["contentType"] as? String,
               (ctype.contains("PLAYLIST") || ctype.contains("PODCAST")),
               !seen.contains(id) {
                let title = (dig(lvm, "metadata", "lockupMetadataViewModel", "title", "content") as? String) ?? ""
                let thumbURL = (firstValue("sources", lvm) as? [[String: Any]])?.last?["url"] as? String ?? ""
                if !title.isEmpty {
                    seen.insert(id)
                    acc.append(PlaylistItem(id: id, title: title, thumbnail: thumbURL, count: playlistCount(lvm)))
                }
            }
            for v in dict.values { walkPlaylistLockups(v, into: &acc, seen: &seen) }
        } else if let arr = node as? [Any] {
            for v in arr { walkPlaylistLockups(v, into: &acc, seen: &seen) }
        }
    }

    /// Best-effort "N videos" badge text from a playlist lockup's thumbnail overlay.
    private static func playlistCount(_ node: Any) -> String {
        var found = ""
        func walk(_ n: Any) {
            if !found.isEmpty { return }
            if let d = n as? [String: Any] {
                if let s = d["content"] as? String,
                   s.range(of: #"^\d[\d,]*\s+video"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    found = s; return
                }
                for v in d.values { walk(v) }
            } else if let a = n as? [Any] { for v in a { walk(v) } }
        }
        walk(node)
        return found
    }

    /// Chronological feed of new uploads from subscribed channels (the /feed/subscriptions page).
    static func subscriptionsFeed(session: FirefoxSession.Session, client: Client) async -> FeedPage {
        var body = context(); body["browseId"] = "FEsubscriptions"
        guard let json = await call(path: "browse", body: body, session: session, client: client) else {
            return FeedPage(videos: [], continuation: nil)
        }
        return page(from: json)
    }

    /// Next page of any browse feed (home, subscriptions, channel…) via its token.
    static func browseContinuation(token: String, session: FirefoxSession.Session?, client: Client) async -> FeedPage {
        var body = context(); body["continuation"] = token
        guard let json = await call(path: "browse", body: body, session: session, client: client) else {
            return FeedPage(videos: [], continuation: nil)
        }
        return page(from: json)
    }

    struct ChannelResult: Sendable {
        let name: String
        let handle: String
        let subscribers: String
        let avatar: String
        let videos: [FeedVideo]
        let continuation: String?
        let subscribed: Bool
    }

    static func channel(channelId: String, session: FirefoxSession.Session?, client: Client) async -> ChannelResult? {
        var body = context()
        body["browseId"] = channelId
        body["params"] = "EgZ2aWRlb3PyBgQKAjoA"   // "Videos" tab
        guard let json = await call(path: "browse", body: body, session: session, client: client) else { return nil }
        let ph: Any = firstValue("pageHeaderViewModel", json) ?? [String: Any]()
        let titleNode: Any = firstValue("title", ph) ?? [String: Any]()
        let name = (firstValue("content", titleNode) as? String) ?? ""

        var parts: [String] = []
        if let rows = firstValue("metadataRows", ph) as? [[String: Any]] {
            for row in rows {
                for p in (row["metadataParts"] as? [[String: Any]] ?? []) {
                    if let t = text(firstValue("text", p)) { parts.append(t) }
                }
            }
        }
        let avatarNode: Any = firstValue("avatar", ph) ?? [String: Any]()
        let avatar = ((firstValue("sources", avatarNode) as? [[String: Any]])?.last?["url"] as? String) ?? ""

        let page = page(from: json)
        return ChannelResult(
            name: name,
            handle: parts.first(where: { $0.hasPrefix("@") }) ?? "",
            subscribers: parts.first(where: { $0.lowercased().contains("subscriber") }) ?? "",
            avatar: avatar,
            videos: page.videos, continuation: page.continuation,
            subscribed: subscribed(inSecondary: json)   // scoped to the header's subscribe button
        )
    }

    struct ShortItem: Content, Sendable {
        let id: String
        let title: String
        let thumbnail: String
    }

    /// Shorts from the home feed (shortsLockupViewModel entries).
    static func shorts(session: FirefoxSession.Session?, client: Client) async -> [ShortItem] {
        var body = context(); body["browseId"] = "FEwhat_to_watch"
        guard let json = await call(path: "browse", body: body, session: session, client: client) else { return [] }
        var acc: [ShortItem] = []
        var seen = Set<String>()
        walkShorts(json, into: &acc, seen: &seen)
        return acc
    }

    private static func walkShorts(_ node: Any, into acc: inout [ShortItem], seen: inout Set<String>) {
        if let dict = node as? [String: Any] {
            if let sl = dict["shortsLockupViewModel"] as? [String: Any],
               let vid = firstValue("videoId", sl) as? String, !seen.contains(vid) {
                let thumbURL = ((firstValue("sources", firstValue("thumbnailViewModel", sl) ?? [:]) as? [[String: Any]])?.last?["url"] as? String) ?? ""
                let title = (sl["accessibilityText"] as? String) ?? ""
                seen.insert(vid)
                acc.append(ShortItem(id: vid, title: title, thumbnail: thumbURL))
            }
            for v in dict.values { walkShorts(v, into: &acc, seen: &seen) }
        } else if let arr = node as? [Any] {
            for v in arr { walkShorts(v, into: &acc, seen: &seen) }
        }
    }

    /// The signed-in user's own channel id (account_menu → the one UC… browseId).
    static func userChannelId(session: FirefoxSession.Session?, client: Client) async -> String? {
        let body = context()
        guard let json = await call(path: "account/account_menu", body: body, session: session, client: client) else { return nil }
        return channelId(in: json)
    }

    struct NotificationItem: Content, Sendable {
        let text: String
        let time: String
        let thumbnail: String
        let videoId: String?
    }

    static func notifications(session: FirefoxSession.Session?, client: Client) async -> [NotificationItem] {
        var body = context()
        body["notificationsMenuRequestType"] = "NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX"
        guard let json = await call(path: "notification/get_notification_menu", body: body, session: session, client: client) else { return [] }
        var acc: [NotificationItem] = []
        walkNotifications(json, into: &acc)
        return acc
    }

    private static func walkNotifications(_ node: Any, into acc: inout [NotificationItem]) {
        if let dict = node as? [String: Any] {
            if let nr = dict["notificationRenderer"] as? [String: Any] {
                let msg = text(nr["shortMessage"]) ?? ""
                if !msg.isEmpty {
                    let thumbURL = ((firstValue("thumbnails", nr) as? [[String: Any]])?.last?["url"] as? String) ?? ""
                    acc.append(NotificationItem(
                        text: msg,
                        time: text(nr["sentTimeText"]) ?? "",
                        thumbnail: thumbURL,
                        videoId: firstValue("videoId", nr["navigationEndpoint"] ?? [:]) as? String
                    ))
                }
            }
            for v in dict.values { walkNotifications(v, into: &acc) }
        } else if let arr = node as? [Any] {
            for v in arr { walkNotifications(v, into: &acc) }
        }
    }

    /// `params` is YouTube's base64 search-filter blob (e.g. `EgPIAQE=` = HDR-only). Omit for a plain search.
    static func search(query: String, session: FirefoxSession.Session?, client: Client, params: String? = nil) async -> FeedPage {
        var body = context(); body["query"] = query
        if let params { body["params"] = params }
        guard let json = await call(path: "search", body: body, session: session, client: client) else {
            return FeedPage(videos: [], continuation: nil)
        }
        return page(from: json)
    }

    /// YouTube's "HDR" search-results filter. Every returned video is HDR-tagged by YouTube,
    /// so no per-video ANDROID_VR probing is needed to populate the HDR shelf.
    static let hdrSearchParams = "EgPIAQE="

    static func searchContinuation(token: String, session: FirefoxSession.Session?, client: Client) async -> FeedPage {
        var body = context(); body["continuation"] = token
        guard let json = await call(path: "search", body: body, session: session, client: client) else {
            return FeedPage(videos: [], continuation: nil)
        }
        return page(from: json)
    }

    private static func page(from json: Any) -> FeedPage {
        var acc: [String: FeedVideo] = [:]
        var order: [String] = []
        walkVideos(json, into: &acc, order: &order)
        return FeedPage(videos: order.compactMap { acc[$0] }, continuation: continuationToken(json))
    }

    /// Subtrees whose continuationItemRenderer belongs to an embedded shelf
    /// (Shorts rows, "More from" shelves, engagement panels) — not the page.
    private static let shelfSubtreeKeys: Set<String> = [
        "richSectionRenderer", "richShelfRenderer", "reelShelfRenderer",
        "shelfRenderer", "horizontalListRenderer", "engagementPanels",
    ]

    /// The PAGE-level "load more" token from a feed / continuation response —
    /// skips shelf subtrees so their inner tokens can't shadow the page token.
    private static func continuationToken(_ node: Any) -> String? {
        if let d = node as? [String: Any] {
            if let cir = d["continuationItemRenderer"] { return firstValue("token", cir) as? String }
            for (k, v) in d where !shelfSubtreeKeys.contains(k) {
                if let r = continuationToken(v) { return r }
            }
        } else if let a = node as? [Any] {
            for v in a { if let r = continuationToken(v) { return r } }
        }
        return nil
    }

    private static let adKeys: Set<String> = [
        "adSlotRenderer", "promotedVideoRenderer", "promotedSparklesWebRenderer",
        "promotedSparklesTextSearchRenderer", "displayAdRenderer", "searchPyvRenderer",
        "compactPromotedVideoRenderer", "statementBannerRenderer",
    ]

    private static func walkVideos(_ node: Any, into acc: inout [String: FeedVideo], order: inout [String]) {
        if let dict = node as? [String: Any] {
            // Skip ad/promoted subtrees entirely.
            if dict.keys.contains(where: { adKeys.contains($0) }) { return }
            // Modern YouTube web home feed: lockupViewModel.
            if let lvm = dict["lockupViewModel"] as? [String: Any] { addLockup(lvm, into: &acc, order: &order) }
            // Legacy renderer (ads / older shelves).
            if let vid = dict["videoId"] as? String, dict["thumbnail"] != nil,
               let title = text(dict["title"]), !title.isEmpty, acc[vid] == nil {
                let channel = text(dict["ownerText"]) ?? text(dict["longBylineText"]) ?? text(dict["shortBylineText"]) ?? ""
                let cid = channelId(in: dict["longBylineText"] ?? [:])
                    ?? channelId(in: dict["shortBylineText"] ?? [:])
                    ?? channelId(in: dict["ownerText"] ?? [:])
                acc[vid] = FeedVideo(
                    id: vid, title: title, channel: channel, channelId: cid,
                    channelAvatar: firstYT3URL(dict),
                    thumbnail: thumb(dict["thumbnail"]),
                    views: text(dict["viewCountText"]), published: text(dict["publishedTimeText"]),
                    durationSeconds: parseDuration(text(dict["lengthText"]))
                )
                order.append(vid)
            }
            for value in dict.values { walkVideos(value, into: &acc, order: &order) }
        } else if let arr = node as? [Any] {
            for value in arr { walkVideos(value, into: &acc, order: &order) }
        }
    }

    private static func addLockup(_ lvm: [String: Any], into acc: inout [String: FeedVideo], order: inout [String]) {
        guard let id = lvm["contentId"] as? String, acc[id] == nil else { return }
        if let ct = lvm["contentType"] as? String, !ct.contains("VIDEO") { return }   // skip playlists/channels
        guard let title = dig(lvm, "metadata", "lockupMetadataViewModel", "title", "content") as? String else { return }

        var parts: [String] = []
        if let rows = dig(lvm, "metadata", "lockupMetadataViewModel", "metadata", "contentMetadataViewModel", "metadataRows") as? [[String: Any]] {
            for row in rows {
                for part in (row["metadataParts"] as? [[String: Any]] ?? []) {
                    if let t = dig(part, "text", "content") as? String { parts.append(t) }
                }
            }
        }
        let thumbURL = (dig(lvm, "contentImage", "thumbnailViewModel", "image", "sources") as? [[String: Any]])?.last?["url"] as? String ?? ""

        acc[id] = FeedVideo(
            id: id, title: title,
            channel: parts.first ?? "",
            channelId: channelId(in: lvm),
            channelAvatar: firstYT3URL(lvm),
            thumbnail: thumbURL,
            views: parts.first(where: { $0.lowercased().contains("view") }),
            published: parts.first(where: { $0.lowercased().contains("ago") }),
            durationSeconds: parseDuration(timeBadge(lvm))
        )
        order.append(id)
    }

    /// The channel avatar URL — the only yt3.* image in a video lockup/renderer
    /// (video thumbnails are i.ytimg.com, so the first yt3 url is the uploader's avatar).
    private static func firstYT3URL(_ node: Any) -> String {
        if let d = node as? [String: Any] {
            if let u = d["url"] as? String, u.contains("yt3.") { return u }
            for v in d.values { let r = firstYT3URL(v); if !r.isEmpty { return r } }
        } else if let a = node as? [Any] {
            for v in a { let r = firstYT3URL(v); if !r.isEmpty { return r } }
        }
        return ""
    }

    /// The uploader's channel id (UC…) — a video lockup/renderer contains exactly one.
    private static func channelId(in node: Any) -> String? {
        if let d = node as? [String: Any] {
            if let b = d["browseId"] as? String, b.hasPrefix("UC") { return b }
            for v in d.values { if let r = channelId(in: v) { return r } }
        } else if let a = node as? [Any] {
            for v in a { if let r = channelId(in: v) { return r } }
        }
        return nil
    }

    // MARK: Mark-as-watched (writes to the signed-in account's watch history)

    private static let cpnAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    /// Client playback nonce: 16 chars from YouTube's CPN alphabet (matches the browser player).
    private static func newCPN() -> String { String((0..<16).map { _ in cpnAlphabet[Int.random(in: 0..<64)] }) }

    /// Registers `videoId` in the signed-in user's YouTube watch history by firing the player's
    /// own "videostats" playback ping — the same request youtube.com sends as you watch. Mirrors
    /// `yt-dlp --mark-watched`: fetch the authenticated WEB player response, take
    /// `playbackTracking.videostatsPlaybackUrl`, append `ver=2` + a fresh CPN, and GET it with the
    /// session cookies (so YouTube attributes the view to the account). Returns true on 2xx.
    static func markWatched(videoId: String, session: FirefoxSession.Session, client: Client) async -> Bool {
        var body = context()
        body["videoId"] = videoId
        body["contentCheckOk"] = true
        body["racyCheckOk"] = true
        guard let json = await call(path: "player", body: body, session: session, client: client),
              let base = dig(json, "playbackTracking", "videostatsPlaybackUrl", "baseUrl") as? String,
              var comps = URLComponents(string: base) else { return false }
        var items = comps.queryItems ?? []
        // Guard against a fallback/substituted player response logging the WRONG video.
        if let docid = items.first(where: { $0.name == "docid" })?.value, docid != videoId { return false }
        // Set (replace, don't blind-append) the params the browser adds when it fires this ping.
        for (name, value) in [("ver", "2"), ("cpn", newCPN()), ("el", "detailpage")] {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        comps.queryItems = items
        guard let pingURL = comps.url?.absoluteString else { return false }
        do {
            let res = try await client.get(URI(string: pingURL), beforeSend: { req in
                req.headers.replaceOrAdd(name: "Cookie", value: session.cookieHeader)
                req.headers.replaceOrAdd(name: "X-Goog-AuthUser", value: "0")   // same account index as the player fetch
                req.headers.replaceOrAdd(name: "User-Agent", value: userAgent)
                req.headers.replaceOrAdd(name: "Referer", value: "\(origin)/watch?v=\(videoId)")
            })
            return (200...299).contains(Int(res.status.code))
        } catch { return false }
    }

    /// Navigate a nested dictionary by successive keys.
    private static func dig(_ obj: Any?, _ keys: String...) -> Any? {
        var cur = obj
        for k in keys {
            guard let d = cur as? [String: Any], let next = d[k] else { return nil }
            cur = next
        }
        return cur
    }

    /// Find the duration badge text (e.g. "7:04") within a lockup's thumbnail overlays.
    private static func timeBadge(_ node: Any) -> String? {
        if let d = node as? [String: Any] {
            if let badge = d["thumbnailBadgeViewModel"] as? [String: Any],
               let t = badge["text"] as? String, t.contains(":"), t.allSatisfy({ $0.isNumber || $0 == ":" }) {
                return t
            }
            for v in d.values { if let r = timeBadge(v) { return r } }
        } else if let a = node as? [Any] {
            for v in a { if let r = timeBadge(v) { return r } }
        }
        return nil
    }

    private static func parseDuration(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return Double(parts.reduce(0) { $0 * 60 + $1 })
    }

    // MARK: Watch page (next → metadata + recommendations)

    struct Comment: Content, Sendable {
        let commentId: String
        let author: String
        let avatar: String
        let text: String
        let published: String
        let likes: String
        let replies: String
    }

    struct WatchMeta: Sendable {
        let title: String
        let channel: String
        let channelId: String
        let subscribers: String
        let views: String
        let published: String
        let description: String
        let likes: String?
        let recommendations: [FeedVideo]
        let commentCount: String
        let comments: [Comment]
        let commentsContinuation: String?
        let subscribed: Bool       // is the signed-in user already subscribed to this channel
        let likeStatus: Int        // -1 disliked, 0 none, 1 liked (signed-in user's current state)
    }

    static func watchInfo(videoId: String, session: FirefoxSession.Session?, client: Client) async -> WatchMeta? {
        var body = context(); body["videoId"] = videoId
        guard let json = await call(path: "next", body: body, session: session, client: client) else { return nil }
        // One descent into the two-column watch layout, then every parse below is
        // scoped to its own column instead of re-scanning the whole response.
        let root = dig(json, "contents", "twoColumnWatchNextResults") ?? json
        let results = dig(root, "results", "results", "contents") ?? root
        let pri = firstValue("videoPrimaryInfoRenderer", results) ?? [:]
        let sec = firstValue("videoSecondaryInfoRenderer", results) ?? [:]
        let owner = firstValue("videoOwnerRenderer", sec) ?? [:]
        let vcr = firstValue("videoViewCountRenderer", pri) ?? [:]

        let title = text(dig(pri, "title")) ?? ""
        guard !title.isEmpty else { return nil }

        var recAcc: [String: FeedVideo] = [:]
        var recOrder: [String] = []
        if let secondary = dig(root, "secondaryResults") ?? firstValue("secondaryResults", root) {
            walkVideos(secondary, into: &recAcc, order: &recOrder)
        }

        // Comments live behind a continuation token in the same `next` response;
        // fetch the first page with one more call.
        var commentCount = ""
        var comments: [Comment] = []
        var commentsCont: String? = nil
        if let token = commentsToken(results) {
            var cbody = context(); cbody["continuation"] = token
            if let cjson = await call(path: "next", body: cbody, session: session, client: client) {
                (commentCount, comments, commentsCont) = parseComments(cjson)
            }
        }

        return WatchMeta(
            title: title,
            channel: text(dig(owner, "title")) ?? "",
            channelId: (firstValue("browseId", owner) as? String) ?? "",
            subscribers: text(dig(owner, "subscriberCountText")) ?? "",
            views: text(dig(vcr, "viewCount")) ?? "",
            published: text(dig(pri, "relativeDateText")) ?? "",
            description: text(firstValue("attributedDescription", sec)) ?? text(dig(sec, "description")) ?? "",
            likes: likeCount(pri),
            recommendations: recOrder.compactMap { recAcc[$0] },
            commentCount: commentCount,
            comments: comments,
            commentsContinuation: commentsCont,
            subscribed: subscribed(inSecondary: sec),
            likeStatus: likeStatus(inPrimary: pri)
        )
    }

    /// Whether the signed-in user is subscribed, read from the secondary info
    /// column's subscribe button (not a whole-response scan).
    private static func subscribed(inSecondary sec: Any) -> Bool {
        let btn = firstValue("subscribeButtonRenderer", sec) ?? firstValue("subscribeButton", sec) ?? sec
        return (firstValue("subscribed", btn) as? Bool) ?? false
    }

    /// The signed-in user's current like state ("LIKE" | "DISLIKE" | "INDIFFERENT"),
    /// read from the primary info column's like/dislike button view model.
    private static func likeStatus(inPrimary pri: Any) -> Int {
        let btn = firstValue("segmentedLikeDislikeButtonViewModel", pri)
               ?? firstValue("likeButtonViewModel", pri) ?? pri
        let raw = ((firstValue("likeStatusEntity", btn) as? [String: Any])?["likeStatus"] as? String)
               ?? (firstValue("likeStatus", btn) as? String) ?? ""
        switch raw { case "LIKE": return 1; case "DISLIKE": return -1; default: return 0 }
    }

    // MARK: Write actions (modify the signed-in account)

    /// Subscribe to / unsubscribe from a channel. Requires the Firefox session.
    static func setSubscription(channelId: String, subscribe: Bool, session: FirefoxSession.Session, client: Client) async -> Bool {
        var body = context()
        body["channelIds"] = [channelId]
        body["params"] = "EgIIAhgA"   // standard subscribe params
        let path = subscribe ? "subscription/subscribe" : "subscription/unsubscribe"
        return await call(path: path, body: body, session: session, client: client) != nil
    }

    /// Set the like state for a video: "like" | "dislike" | "none". Requires the session.
    static func setLike(videoId: String, state: String, session: FirefoxSession.Session, client: Client) async -> Bool {
        var body = context()
        body["target"] = ["videoId": videoId]
        let path: String
        switch state {
        case "like":    path = "like/like"
        case "dislike": path = "like/dislike"
        default:        path = "like/removelike"
        }
        return await call(path: path, body: body, session: session, client: client) != nil
    }

    /// The comments continuation token from the initial next response.
    private static func commentsToken(_ node: Any) -> String? {
        if let d = node as? [String: Any] {
            if (d["sectionIdentifier"] as? String) == "comment-item-section" {
                return firstValue("token", d) as? String
            }
            for v in d.values { if let r = commentsToken(v) { return r } }
        } else if let a = node as? [Any] {
            for v in a { if let r = commentsToken(v) { return r } }
        }
        return nil
    }

    /// Fetch the next page of comments for continuous scroll.
    static func moreComments(token: String, session: FirefoxSession.Session?, client: Client) async -> (comments: [Comment], continuation: String?) {
        var body = context(); body["continuation"] = token
        guard let json = await call(path: "next", body: body, session: session, client: client) else { return ([], nil) }
        let (_, comments, cont) = parseComments(json)
        return (comments, cont)
    }

    /// Parse the comments continuation response (modern commentEntityPayload format).
    private static func parseComments(_ json: Any) -> (String, [Comment], String?) {
        let count = text(firstValue("countText", firstValue("commentsHeaderRenderer", json) ?? [:])) ?? ""
        var out: [Comment] = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                if let p = d["commentEntityPayload"] as? [String: Any] { out.append(comment(from: p)) }
                for v in d.values { walk(v) }
            } else if let a = node as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(json)
        return (count, out, commentsPageToken(json))
    }

    /// The PAGE-level comments continuation — the `continuationItemRenderer` that is NOT
    /// inside a reply thread. (The generic first-match DFS returned a leading thread's
    /// "show N replies" token, so paging fetched replies instead of the next comment page.)
    private static func commentsPageToken(_ node: Any) -> String? {
        if let d = node as? [String: Any] {
            if let cir = d["continuationItemRenderer"] as? [String: Any],
               let t = firstValue("token", cir) as? String { return t }
            for (k, v) in d where k != "replies" && k != "commentRepliesRenderer" {
                if let r = commentsPageToken(v) { return r }
            }
        } else if let a = node as? [Any] {
            for v in a { if let r = commentsPageToken(v) { return r } }
        }
        return nil
    }

    private static func comment(from p: [String: Any]) -> Comment {
        let author = p["author"] as? [String: Any] ?? [:]
        let props = p["properties"] as? [String: Any] ?? [:]
        let toolbar = p["toolbar"] as? [String: Any] ?? [:]
        return Comment(
            commentId: (props["commentId"] as? String) ?? "",
            author: (author["displayName"] as? String) ?? "",
            avatar: (author["avatarThumbnailUrl"] as? String) ?? "",
            text: text(props["content"]) ?? "",
            published: (props["publishedTime"] as? String) ?? "",
            likes: (toolbar["likeCountNotliked"] as? String) ?? (toolbar["likeCountLiked"] as? String) ?? "",
            replies: (toolbar["replyCount"] as? String) ?? ""
        )
    }

    /// Best-effort like count from the modern like button view model.
    private static func likeCount(_ json: Any) -> String? {
        guard let like = firstValue("likeButtonViewModel", json) else { return nil }
        if let t = text(firstValue("title", like)), !t.isEmpty { return t }
        return nil
    }

    /// First value found for `key` anywhere in the JSON tree.
    private static func firstValue(_ key: String, _ node: Any) -> Any? {
        if let d = node as? [String: Any] {
            if let v = d[key] { return v }
            for v in d.values { if let r = firstValue(key, v) { return r } }
        } else if let a = node as? [Any] {
            for v in a { if let r = firstValue(key, v) { return r } }
        }
        return nil
    }

    // MARK: Identity (account_menu → name + photo)

    static func profile(session: FirefoxSession.Session, client: Client) async -> GoogleOAuth.Profile? {
        guard let json = await call(path: "account/account_menu", body: context(), session: session, client: client) else { return nil }
        var name: String?
        var photo = ""
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if name == nil, let n = text(dict["accountName"]) { name = n }
                if photo.isEmpty { photo = thumb(dict["accountPhoto"]) }
                for value in dict.values { walk(value) }
            } else if let arr = node as? [Any] {
                for value in arr { walk(value) }
            }
        }
        walk(json)
        guard let n = name else { return nil }
        return GoogleOAuth.Profile(name: n, email: "", picture: photo)
    }

    // MARK: JSON helpers

    private static func text(_ node: Any?) -> String? {
        if let s = node as? String { return s }
        if let d = node as? [String: Any] {
            if let s = d["simpleText"] as? String { return s }
            if let s = d["content"] as? String { return s }   // attributedDescription / viewModel text
            if let runs = d["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
        }
        return nil
    }
    private static func thumb(_ node: Any?) -> String {
        guard let d = node as? [String: Any],
              let thumbs = d["thumbnails"] as? [[String: Any]],
              let url = (thumbs.last?["url"]) as? String else { return "" }
        return url.hasPrefix("//") ? "https:" + url : url
    }
}
