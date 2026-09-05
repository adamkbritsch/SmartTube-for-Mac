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

    /// One overflow-menu action YouTube itself offers for a feed item, carried verbatim from the
    /// payload (label included) so the app never invents an action YouTube doesn't support here.
    ///
    /// `kind` is derived from the menu item's ICON, never its array position: the same index means
    /// different things per feed — item 5 is "Not interested" on the home feed but "Remove from
    /// watch history" on FEhistory. Position-keying would ship a "Don't suggest this" button that
    /// silently deletes watch history. Feeds also differ in what they offer at all (home: Not
    /// interested + Don't recommend channel; subscriptions: Hide; history: Remove from watch
    /// history; search: none), so an empty list is normal, not an error.
    struct FeedbackAction: Sendable {
        let kind: String        // "notInterested" | "notChannel" | "removeFromHistory"
        let label: String       // YouTube's own wording, verbatim
        let token: String       // POST to /youtubei/v1/feedback
        let undoToken: String?  // reverses it through the same endpoint
    }

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
        var previewUrl: String? = nil   // animated hover preview (an_webp), if YouTube provides one
        var feedback: [FeedbackAction] = []   // overflow-menu actions; empty where YouTube offers none
        var playlistId: String? = nil        // set → this item IS a playlist (id == contentId)
        var videoCountText: String? = nil    // playlist badge, YouTube's own wording ("51 videos")
        var isShort: Bool = false            // came from a shortsLockupViewModel (vertical, /shorts)
        var verified: Bool = false           // channel carries YouTube's verified badge
    }

    /// The signed animated-preview URL (`i.ytimg.com/an_webp/…mqdefault_6s.webp`) YouTube ships
    /// inside a video's renderer for the hover snippet. Its `sqp`/`rs` params are signed, so it
    /// can only be lifted from the response — search the video's own node subtree for it.
    private static func movingThumb(_ node: Any) -> String? {
        if let d = node as? [String: Any] {
            for (k, v) in d {
                if k == "url", let s = v as? String, s.contains("an_webp") { return s }
                if let r = movingThumb(v) { return r }
            }
        } else if let a = node as? [Any] {
            for v in a { if let r = movingThumb(v) { return r } }
        }
        return nil
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

    struct ChannelTab: Sendable {
        let slug: String       // locale-independent: featured | videos | shorts | streams | playlists | podcasts
        let title: String      // YouTube's own label, in the session's language
        let params: String     // browse params that select this tab
        let selected: Bool
    }

    struct ChannelResult: Sendable {
        let name: String
        let handle: String
        let subscribers: String
        let avatar: String
        let videos: [FeedVideo]
        let continuation: String?
        let subscribed: Bool
        let tabs: [ChannelTab]
    }

    /// Tabs whose contents this app can actually render in a card grid. Posts/Store/Search return
    /// nothing a grid can show, and Shows came back empty on every channel probed — offering them
    /// would just be a tab that lands on "No videos".
    private static let renderableTabSlugs = ["featured", "videos", "shorts", "streams", "playlists", "podcast"]

    /// The tab's stable slug, read out of its own browse params rather than its title: the params
    /// are protobuf whose first field is the tab name as plain text ("videos", "playlists", …), so
    /// this keeps working whatever language YouTube answers in.
    private static func tabSlug(fromParams params: String) -> String? {
        let unescaped = params.removingPercentEncoding ?? params
        var padded = unescaped
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded) else { return nil }
        let bytes = [UInt8](data)
        // field 1 (0x12 = tag 2, length-delimited) → length → ASCII name
        guard bytes.count > 2, bytes[0] == 0x12 else { return nil }
        let len = Int(bytes[1])
        guard len > 0, bytes.count >= 2 + len else { return nil }
        let name = String(decoding: bytes[2..<(2 + len)], as: UTF8.self)
        return name.allSatisfy { $0.isLetter } ? name : nil
    }

    private static func channelTabs(_ json: Any) -> [ChannelTab] {
        guard let tabs = dig(json, "contents", "twoColumnBrowseResultsRenderer", "tabs") as? [[String: Any]] else { return [] }
        var out: [ChannelTab] = []
        for t in tabs {
            guard let r = (t["tabRenderer"] ?? t["expandableTabRenderer"]) as? [String: Any],
                  let title = r["title"] as? String,
                  let params = dig(r, "endpoint", "browseEndpoint", "params") as? String,
                  let slug = tabSlug(fromParams: params),
                  renderableTabSlugs.contains(where: { slug.hasPrefix($0) }) else { continue }
            out.append(ChannelTab(slug: slug, title: title,
                                  params: params.removingPercentEncoding ?? params,
                                  selected: (r["selected"] as? Bool) ?? false))
        }
        return out
    }

    static func channel(channelId: String, tabParams: String? = nil, session: FirefoxSession.Session?, client: Client) async -> ChannelResult? {
        var body = context()
        body["browseId"] = channelId
        // Default to the Videos tab, as before; a tab the user picked comes in as its own params.
        body["params"] = tabParams ?? "EgZ2aWRlb3PyBgQKAjoA"
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

        // A channel tab can legitimately be a wall of playlists (Playlists/Podcasts) or Shorts, so
        // both are parsed here — unlike the home feed, which stays videos-only.
        let page = page(from: json, includePlaylists: true, includeShorts: true)
        return ChannelResult(
            name: name,
            handle: parts.first(where: { $0.hasPrefix("@") }) ?? "",
            subscribers: parts.first(where: { $0.lowercased().contains("subscriber") }) ?? "",
            avatar: avatar,
            videos: page.videos, continuation: page.continuation,
            subscribed: subscribed(inSecondary: json),  // scoped to the header's subscribe button
            tabs: channelTabs(json)
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
        // The one surface where playlist lockups come through (the HDR shelf reuses this with
        // params and simply gets none back from that filter).
        return page(from: json, includePlaylists: true)
    }

    /// YouTube's "HDR" search-results filter. Every returned video is HDR-tagged by YouTube,
    /// so no per-video ANDROID_VR probing is needed to populate the HDR shelf.
    static let hdrSearchParams = "EgPIAQE="

    static func searchContinuation(token: String, session: FirefoxSession.Session?, client: Client) async -> FeedPage {
        var body = context(); body["continuation"] = token
        guard let json = await call(path: "search", body: body, session: session, client: client) else {
            return FeedPage(videos: [], continuation: nil)
        }
        return page(from: json, includePlaylists: true)
    }

    private static func page(from json: Any, includePlaylists: Bool = false, includeShorts: Bool = false) -> FeedPage {
        var acc: [String: FeedVideo] = [:]
        var order: [String] = []
        walkVideos(json, into: &acc, order: &order, includePlaylists: includePlaylists, includeShorts: includeShorts)
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

    private static func walkVideos(_ node: Any, into acc: inout [String: FeedVideo], order: inout [String], includePlaylists: Bool = false, includeShorts: Bool = false) {
        if let dict = node as? [String: Any] {
            // Skip ad/promoted subtrees entirely.
            if dict.keys.contains(where: { adKeys.contains($0) }) { return }
            // Modern YouTube web home feed: lockupViewModel.
            if let lvm = dict["lockupViewModel"] as? [String: Any] { addLockup(lvm, into: &acc, order: &order, includePlaylists: includePlaylists) }
            // A channel's Shorts tab is entirely shortsLockupViewModel — a different shape the home
            // feed deliberately does NOT pull in (it would inject Shorts into the main grid).
            if includeShorts, let sl = dict["shortsLockupViewModel"] as? [String: Any] {
                addShortLockup(sl, into: &acc, order: &order)
            }
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
                    durationSeconds: parseDuration(text(dict["lengthText"])),
                    previewUrl: movingThumb(dict),
                    verified: verifiedBadge(in: dict["ownerBadges"] ?? [])
                )
                order.append(vid)
            }
            for value in dict.values { walkVideos(value, into: &acc, order: &order, includePlaylists: includePlaylists, includeShorts: includeShorts) }
        } else if let arr = node as? [Any] {
            for value in arr { walkVideos(value, into: &acc, order: &order, includePlaylists: includePlaylists, includeShorts: includeShorts) }
        }
    }

    /// Icon → our stable kind. An UNKNOWN icon is dropped, never guessed: firing an unrecognised
    /// feedback token is how you'd silently wipe someone's watch history.
    private static func feedbackKind(icon: String?) -> String? {
        switch icon {
        case "NOT_INTERESTED": return "notInterested"      // "Not interested" (home) / "Hide" (subs)
        case "REMOVE":         return "notChannel"         // "Don't recommend channel"
        case "DELETE":         return "removeFromHistory"  // "Remove from watch history"
        default:               return nil
        }
    }

    /// The overflow-menu feedback actions for a modern lockup, read from the menu sheet YouTube
    /// ships inline with every feed item. Verified against a live signed-in home feed: every item
    /// carried its tokens at exactly this path, and each endpoint's own `contentId` matched the
    /// lockup — which we assert, so a shifted parse can't attach one video's token to another.
    private static func feedbackActions(inLockup lvm: [String: Any], contentId: String) -> [FeedbackAction] {
        guard let items = dig(lvm, "metadata", "lockupMetadataViewModel", "menuButton",
                              "buttonViewModel", "onTap", "innertubeCommand", "showSheetCommand",
                              "panelLoadingStrategy", "inlineContent", "sheetViewModel",
                              "content", "listViewModel", "listItems") as? [[String: Any]] else { return [] }
        var out: [FeedbackAction] = []
        for item in items {
            guard let liv = item["listItemViewModel"] as? [String: Any],
                  let ep = dig(liv, "rendererContext", "commandContext", "onTap",
                               "innertubeCommand", "feedbackEndpoint") as? [String: Any],
                  let token = ep["feedbackToken"] as? String, !token.isEmpty
            else { continue }
            // Only accept a token that YouTube itself scoped to THIS video.
            if let epID = ep["contentId"] as? String, epID != contentId { continue }
            let icon = dig(liv, "leadingImage", "sources") as? [[String: Any]]
            let iconName = (icon?.first?["clientResource"] as? [String: Any])?["imageName"] as? String
            guard let kind = feedbackKind(icon: iconName) else { continue }
            let label = (dig(liv, "title", "content") as? String) ?? kind
            out.append(FeedbackAction(kind: kind, label: label, token: token,
                                      undoToken: firstValue("undoToken", ep) as? String))
        }
        return out
    }

    /// True for a metadata part that is a view/date/watching stat rather than a channel name.
    private static func isStatText(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.contains("view") || l.contains("watching") || l.hasSuffix("ago")
            || l.contains("streamed") || l.contains("premiere")
    }

    /// Collection lockups that open as a playlist (albums and podcasts carry playlist ids too).
    private static let playlistLockupTypes = ["PLAYLIST", "ALBUM", "PODCAST"]

    private static func addLockup(_ lvm: [String: Any], into acc: inout [String: FeedVideo], order: inout [String], includePlaylists: Bool = false) {
        guard let id = lvm["contentId"] as? String, acc[id] == nil else { return }
        let ct = lvm["contentType"] as? String ?? ""
        if includePlaylists, playlistLockupTypes.contains(where: { ct.contains($0) }) {
            addPlaylistLockup(lvm, id: id, into: &acc, order: &order)
            return
        }
        if !ct.isEmpty, !ct.contains("VIDEO") { return }   // skip playlists/channels/mixes elsewhere
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
            // parts.first is the uploader on the home feed and in search, but on a CHANNEL's own
            // tab the uploader is implicit and the first part is metadata instead — so every card
            // there showed "1.6M views" where the channel name goes, duplicating the line under it.
            // Take the first part that isn't a stat.
            channel: parts.first(where: { !isStatText($0) }) ?? "",
            channelId: channelId(in: lvm),
            channelAvatar: firstYT3URL(lvm),
            thumbnail: thumbURL,
            views: parts.first(where: { $0.lowercased().contains("view") }),
            published: parts.first(where: { $0.lowercased().contains("ago") }),
            durationSeconds: parseDuration(timeBadge(lvm)),
            previewUrl: movingThumb(lvm),
            feedback: feedbackActions(inLockup: lvm, contentId: id),
            // Scan the whole lockup: the byline badge is not always under `metadata`, and the
            // match requires a VERIFIED-styled badge specifically, so thumbnail badges like "4K"
            // or "New" can't produce a false positive.
            verified: verifiedBadge(in: lvm)
        )
        order.append(id)
    }

    /// A playlist/album/podcast search result. Shape (probed live): thumbnail under
    /// `collectionThumbnailViewModel.primaryThumbnail.thumbnailViewModel`, the "51 videos" badge in
    /// its overlays, title on the shared metadata path, first metadata part = the owner's name.
    private static func addPlaylistLockup(_ lvm: [String: Any], id: String, into acc: inout [String: FeedVideo], order: inout [String]) {
        // Never surface Mixes (RD…): they're per-session radios, and browsing one returns an empty
        // page (verified live) — the card would open onto nothing.
        guard !id.hasPrefix("RD") else { return }
        guard let title = dig(lvm, "metadata", "lockupMetadataViewModel", "title", "content") as? String else { return }
        var parts: [String] = []
        if let rows = dig(lvm, "metadata", "lockupMetadataViewModel", "metadata", "contentMetadataViewModel", "metadataRows") as? [[String: Any]] {
            for row in rows {
                for part in (row["metadataParts"] as? [[String: Any]] ?? []) {
                    if let t = dig(part, "text", "content") as? String { parts.append(t) }
                }
            }
        }
        let thumbVM = dig(lvm, "contentImage", "collectionThumbnailViewModel", "primaryThumbnail", "thumbnailViewModel") as? [String: Any] ?? [:]
        let thumbURL = (dig(thumbVM, "image", "sources") as? [[String: Any]])?.last?["url"] as? String ?? ""
        // The metadata rows differ by surface: in SEARCH the first part is the owner's name, but on
        // a channel's own Playlists tab the owner is implicit and the parts are UI chrome instead
        // ("View full playlist", "Updated 3 days ago"). Taking parts.first blindly put "View full
        // playlist" in the byline, complete with a verified badge and a "V" avatar.
        let chrome = ["view full playlist", "view full podcast", "playlist", "podcast", "album"]
        let owner = parts.first { p in
            let l = p.lowercased()
            return !chrome.contains(l) && !l.hasPrefix("updated")
                && !l.hasSuffix(" videos") && !l.hasSuffix(" video")
                && !l.hasSuffix(" episodes") && !l.hasSuffix(" episode")
        } ?? ""
        acc[id] = FeedVideo(
            id: id, title: title,
            channel: owner,
            channelId: owner.isEmpty ? nil : channelId(in: lvm),
            channelAvatar: owner.isEmpty ? "" : firstYT3URL(lvm),
            thumbnail: thumbURL,
            views: nil,
            published: parts.first { $0.lowercased().hasPrefix("updated") },
            durationSeconds: nil,
            playlistId: id,
            videoCountText: badgeText(in: thumbVM)
        )
        order.append(id)
    }

    /// One Shorts entry. `accessibilityText` reads "Title, 677 thousand views - play Short", so the
    /// title is the part before the last comma — the only place the plain title is exposed.
    private static func addShortLockup(_ sl: [String: Any], into acc: inout [String: FeedVideo], order: inout [String]) {
        guard let vid = firstValue("videoId", sl) as? String, acc[vid] == nil else { return }
        let thumb = ((firstValue("sources", firstValue("thumbnailViewModel", sl) ?? [:]) as? [[String: Any]])?.last?["url"] as? String)
            ?? ((firstValue("thumbnails", sl) as? [[String: Any]])?.last?["url"] as? String) ?? ""
        var title = (sl["accessibilityText"] as? String) ?? ""
        if let r = title.range(of: ", ", options: .backwards) { title = String(title[..<r.lowerBound]) }
        acc[vid] = FeedVideo(id: vid, title: title, channel: "", channelId: nil, channelAvatar: "",
                             thumbnail: thumb, views: nil, published: nil, durationSeconds: nil,
                             isShort: true)
        order.append(vid)
    }

    /// Whether this item's channel carries YouTube's VERIFIED badge.
    ///
    /// The app used to draw `checkmark.seal.fill` on every single card and channel row with no
    /// backing data at all — so an unverified channel was shown as verified. YouTube ships the real
    /// thing two ways depending on the surface: legacy renderers put it in `ownerBadges` as a
    /// `metadataBadgeRenderer` with style BADGE_STYLE_TYPE_VERIFIED, and the newer view models use
    /// an icon/type of CHECK_CIRCLE_FILLED. Both are checked; anything else is treated as NOT
    /// verified, because inventing this badge is worse than omitting it.
    private static func verifiedBadge(in node: Any) -> Bool {
        if let d = node as? [String: Any] {
            if let style = d["style"] as? String, style.contains("VERIFIED") { return true }
            if let icon = d["iconName"] as? String ?? d["iconType"] as? String,
               icon.contains("CHECK_CIRCLE") { return true }
            for (k, v) in d {
                // Don't descend into nested items — a shelf's other cards would leak their badges in.
                if k == "contents" || k == "items" { continue }
                if verifiedBadge(in: v) { return true }
            }
        } else if let a = node as? [Any] {
            for v in a { if verifiedBadge(in: v) { return true } }
        }
        return false
    }

    /// First thumbnail-overlay badge text in the subtree ("51 videos", "Album", …).
    private static func badgeText(in node: Any) -> String? {
        if let d = node as? [String: Any] {
            if let b = d["thumbnailBadgeViewModel"] as? [String: Any], let t = b["text"] as? String { return t }
            for v in d.values { if let r = badgeText(in: v) { return r } }
        } else if let a = node as? [Any] {
            for v in a { if let r = badgeText(in: v) { return r } }
        }
        return nil
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
        /// The count YouTube shows once YOU have liked it — shipped alongside the normal one, so
        /// the number can flip on click without refetching the page.
        var likesLiked: String = ""
        let replies: String
        /// Links this comment to its toolbar state entity (which holds the current vote).
        var toolbarStateKey: String = ""
        /// Continuation that loads THIS comment's replies. Empty when it has none — the client
        /// shows the reply count as a plain label in that case rather than a dead expander.
        var repliesToken: String = ""
        /// Vote tokens for THIS comment, straight from YouTube's own payload. Empty when the user
        /// is signed out or YouTube offered none — the client hides the buttons rather than
        /// showing controls that cannot work.
        var likeToken: String = ""
        var unlikeToken: String = ""
        var dislikeToken: String = ""
        var undislikeToken: String = ""
        var likeState: Int = 0     // -1 disliked, 0 neither, 1 liked
    }

    struct WatchMeta: Sendable {
        let title: String
        let channel: String
        let channelId: String
        let channelAvatar: String   // the uploader's real profile picture
        let channelVerified: Bool   // YouTube's verified badge for this channel
        let subscribers: String
        let views: String
        let published: String
        let description: String
        let descriptionLinks: [DescriptionLink]
        let likes: String?
        let recommendations: [FeedVideo]
        let commentCount: String
        let comments: [Comment]
        let commentsContinuation: String?
        let subscribed: Bool       // is the signed-in user already subscribed to this channel
        let likeStatus: Int        // -1 disliked, 0 none, 1 liked (signed-in user's current state)
    }

    /// Real link targets inside a description. YouTube renders links as DISPLAY text
    /// (`youtu.be/…`, `bit.ly/…`, or a truncated `example.com/very/lo...`) and keeps the true
    /// destination in the run's endpoint — so the flat `content` string alone loses it. The
    /// `attributedDescription` object carries `commandRuns[]` with `{startIndex, length, onTap…url}`,
    /// and outbound links are wrapped as `youtube.com/redirect?q=<encoded real URL>`, unwrapped here.
    /// Offsets are UTF-16 code units (JS string semantics); the client re-validates them.
    static func descriptionLinks(_ node: Any?) -> [DescriptionLink] {
        guard let d = node as? [String: Any],
              let content = d["content"] as? String,
              let runs = d["commandRuns"] as? [[String: Any]] else { return [] }
        let utf16 = Array(content.utf16)
        var out: [DescriptionLink] = []
        for run in runs {
            guard let start = run["startIndex"] as? Int,
                  let len = run["length"] as? Int,
                  start >= 0, len > 0, start + len <= utf16.count else { continue }
            // The endpoint URL lives a few keys down; take whichever is present.
            guard var url = firstValue("url", run["onTap"]) as? String, !url.isEmpty else { continue }
            url = unwrapRedirect(url)
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            let display = String(decoding: utf16[start..<(start + len)], as: UTF16.self)
            out.append(DescriptionLink(text: display, url: url, start: start, length: len))
        }
        return out
    }

    /// `https://www.youtube.com/redirect?q=<percent-encoded target>` → the target.
    private static func unwrapRedirect(_ url: String) -> String {
        guard url.contains("/redirect?"), let comps = URLComponents(string: url),
              let q = comps.queryItems?.first(where: { $0.name == "q" })?.value, !q.isEmpty else { return url }
        return q
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
            // The watch page drew AvatarView(url: nil) and an unconditional verified badge, so the
            // uploader always got a monogram and always looked verified. Both are in `owner`.
            channelAvatar: firstYT3URL(owner),
            channelVerified: verifiedBadge(in: owner),
            subscribers: text(dig(owner, "subscriberCountText")) ?? "",
            views: text(dig(vcr, "viewCount")) ?? "",
            published: text(dig(pri, "relativeDateText")) ?? "",
            description: text(firstValue("attributedDescription", sec)) ?? text(dig(sec, "description")) ?? "",
            descriptionLinks: descriptionLinks(firstValue("attributedDescription", sec)),
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
    /// Send one feedback token ("Not interested", "Don't recommend channel", an undo, …).
    ///
    /// Unlike the other write actions here, HTTP 200 is NOT treated as success: YouTube answers a
    /// stale or rejected token with 200 and `isProcessed: false`, so the `call(...) != nil` idiom
    /// used by setSubscription/setLike would report a silent phantom success. Parse the body.
    static func sendFeedback(token: String, session: FirefoxSession.Session, client: Client) async -> Bool {
        var body = context()
        body["feedbackTokens"] = [token]
        body["isFeedbackTokenUnencrypted"] = false
        body["shouldMerge"] = false
        guard let json = await call(path: "feedback", body: body, session: session, client: client) else { return false }
        // Accept only an explicit processed:true from the response.
        if let processed = firstValue("isProcessed", json) as? Bool { return processed }
        if let ok = firstValue("success", json) as? Bool { return ok }
        return false
    }

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

        // SECOND PASS. A comment's vote buttons are NOT in its own payload: the tokens live in
        // frameworkUpdates.entityBatchUpdate.mutations as engagementToolbarSurfaceEntityPayload
        // (like/unlike/dislike/undislike commands), and the current vote in
        // engagementToolbarStateEntityPayload. Both are keyed by opaque base64 entity keys, but
        // every one of those keys embeds the plain comment id, so they can be joined on it.
        let (tokens, states) = commentToolbars(json)
        let replyTokens = commentReplyTokens(json)
        out = out.map { c in
            var c = c
            c.repliesToken = replyTokens[c.commentId] ?? ""
            if let t = tokens[c.commentId] {
                c.likeToken = t.like; c.unlikeToken = t.unlike
                c.dislikeToken = t.dislike; c.undislikeToken = t.undislike
            }
            if let st = states[c.toolbarStateKey] { c.likeState = st }
            return c
        }
        return (count, out, commentsPageToken(json))
    }

    /// commentId → the continuation that loads that comment's replies.
    ///
    /// commentThreadRenderer carries both halves directly: the comment's own id under
    /// commentViewModel.commentViewModel.commentId, and the reply continuation under `replies`.
    /// No entity-key decoding needed here, unlike the vote tokens.
    private static func commentReplyTokens(_ node: Any) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ n: Any) {
            if let d = n as? [String: Any] {
                if let t = d["commentThreadRenderer"] as? [String: Any],
                   let id = dig(t, "commentViewModel", "commentViewModel", "commentId") as? String,
                   let replies = t["replies"],
                   let token = firstValue("token", replies) as? String {
                    out[id] = token
                }
                for v in d.values { walk(v) }
            } else if let a = n as? [Any] {
                for v in a { walk(v) }
            }
        }
        walk(node)
        return out
    }

    private struct CommentTokens { var like = ""; var unlike = ""; var dislike = ""; var undislike = "" }

    /// Join the toolbar entities to their comments. Returns (commentId → tokens, stateKey → vote).
    private static func commentToolbars(_ json: Any) -> ([String: CommentTokens], [String: Int]) {
        guard let muts = dig(json, "frameworkUpdates", "entityBatchUpdate", "mutations") as? [[String: Any]] else {
            return ([:], [:])
        }
        var tokens: [String: CommentTokens] = [:]
        var states: [String: Int] = [:]
        for m in muts {
            guard let payload = m["payload"] as? [String: Any] else { continue }

            if let st = payload["engagementToolbarStateEntityPayload"] as? [String: Any],
               let key = st["key"] as? String {
                switch st["likeState"] as? String {
                case "TOOLBAR_LIKE_STATE_LIKED":    states[key] = 1
                case "TOOLBAR_LIKE_STATE_DISLIKED": states[key] = -1
                default:                            states[key] = 0
                }
            }

            if let surf = payload["engagementToolbarSurfaceEntityPayload"] as? [String: Any],
               let key = (surf["key"] as? String) ?? (m["entityKey"] as? String),
               let cid = commentId(inEntityKey: key) {
                func token(_ name: String) -> String {
                    (dig(surf, name, "innertubeCommand", "performCommentActionEndpoint", "action") as? String) ?? ""
                }
                tokens[cid] = CommentTokens(like: token("likeCommand"), unlike: token("unlikeCommand"),
                                            dislike: token("dislikeCommand"), undislike: token("undislikeCommand"))
            }
        }
        return (tokens, states)
    }

    /// The comment id embedded in a toolbar entity key. The key is base64 (URL-escaped) protobuf
    /// whose first field is the id as plain ASCII — e.g. "Ugwi…AaABAg" — so the join needs no
    /// protobuf parsing, just the leading length-delimited string.
    private static func commentId(inEntityKey key: String) -> String? {
        let unescaped = key.removingPercentEncoding ?? key
        var padded = unescaped
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded) else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count > 2, bytes[0] == 0x12 else { return nil }
        let len = Int(bytes[1])
        guard len > 0, bytes.count >= 2 + len else { return nil }
        // The surface key's field carries a SUFFIX the comment's own id does not have
        // ("Ugwi…AaABAg/12"), so trim at the first separator or the join silently never matches.
        var id = String(decoding: bytes[2..<(2 + len)], as: UTF8.self)
        if let cut = id.firstIndex(where: { $0 == "/" || $0 == " " }) { id = String(id[..<cut]) }
        return id.hasPrefix("Ug") ? id : nil
    }

    /// Cast / clear a vote on one comment. The token IS the action — it comes from YouTube's own
    /// payload, so this can only ever perform something YouTube offered for that comment.
    static func performCommentAction(token: String, session: FirefoxSession.Session, client: Client) async -> Bool {
        guard !token.isEmpty else { return false }
        var body = context()
        body["actions"] = [token]
        return await call(path: "comment/perform_comment_action", body: body, session: session, client: client) != nil
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
            likesLiked: (toolbar["likeCountLiked"] as? String) ?? "",
            replies: (toolbar["replyCount"] as? String) ?? "",
            toolbarStateKey: (props["toolbarStateKey"] as? String) ?? ""
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
