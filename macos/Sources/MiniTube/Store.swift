import Foundation
import AppKit

/// Second-by-second playback readouts, isolated so only the views that show them
/// (the enhance bar) re-render — not the whole tree hanging off Store.
@MainActor
final class PlaybackState: ObservableObject {
    @Published var height: Int = 0            // decoded height of the playing video (0 = unknown)
    @Published var enhanceActive: Bool = false // true → the GPU sharpen is currently applied
    @Published var hdr: Bool = false           // true → the current video is genuinely HDR
}

/// Talks to the shared backend and polls `/api/settings` every 2s. When the
/// companion Firefox extension (or the web UI) changes a setting, this store's
/// `@Published settings` updates and the whole native UI re-renders — that's the
/// extension-affects-the-Swift-app cross-effect.
@MainActor
final class Store: ObservableObject {
    @Published var settings = Settings.default
    @Published var videos: [VideoListItem] = []
    @Published var reachable = false
    @Published var account = Account.empty
    @Published var device: DeviceInfo?   // non-nil while a code sign-in is in progress
    @Published var watchVideoId: String?   // non-nil → watch page open for this video
    @Published var watchInfo: WatchInfo?   // metadata for the open watch page
    @Published var channelId: String?      // non-nil → channel page open (set immediately on tap)
    @Published var channelInfo: ChannelInfo?  // header + first page of the open channel
    @Published var playlists: [Playlist]?  // non-nil → Playlists grid page
    @Published var shortsFeed: [ShortItem]?  // non-nil → Shorts grid page
    private var playlistId = ""            // current playlist detail (WL | LL | PL…)
    private var playlistTitle = ""
    private var playlistFromGrid = false   // playlist detail was opened from the Playlists grid
    /// Live playback readouts (resolution/sharpen/HDR) live in their OWN observable:
    /// they change every second during playback, and as @Published members of Store
    /// they re-rendered the entire view tree (sidebar, header, feed) each tick.
    let playback = PlaybackState()
    @Published var fullscreen = false      // true → fullscreen player overlay on top of the watch page
    @Published var loadingMore = false     // fetching the next feed page
    @Published var searchQuery = ""        // non-empty → feed shows search results
    @Published var feedMode = "home"       // "home" | "subscriptions" — which feed the grid shows
    @Published var homeLoading = true      // true until the first (personalized) home feed loads
    @Published var hdrVideos: [VideoListItem] = []   // HDR videos from the feed's channels (HDR chip)
    @Published var hdrLoading = false         // probing the feed's channels for HDR videos
    private var hdrProbedKey = ""             // which channel set we last probed
    private var feedContinuation: String?  // "load more" token for continuous scroll

    private let base = "http://127.0.0.1:8080"   // loopback IP (ATS-exempt for plain HTTP)
    private var pollTask: Task<Void, Never>?

    func start() {
        // No initial load: we adopt the Firefox session first (autoConnectIfNeeded),
        // then load the personalized feed — so the seeded catalog never flashes.
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.fetchSettings()
                // Account changes are rare after bootstrap — poll it at 1/5 rate once
                // connected (settings stay at 2s so toggles keep feeling instant).
                let bootstrapping = await self?.stillBootstrapping ?? false
                if bootstrapping || tick % 5 == 0 { await self?.fetchAccount() }
                await self?.autoConnectIfNeeded()
                tick &+= 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var stillBootstrapping: Bool { !connected || homeLoading }

    private var connected = false

    /// Silently adopt the existing Firefox YouTube login on launch (no sign-in sheet)
    /// so the app is personalized out of the box. Retries each poll until it succeeds.
    func autoConnectIfNeeded() async {
        // Runs only during the initial bootstrap (while homeLoading). Adopt the Firefox
        // session, THEN load — so the first thing shown is the personalized feed, not the
        // seeded catalog. Retries each poll until the backend is up / a result comes back.
        guard reachable else { return }
        // (1) Adopt the Firefox session ONCE — `connected` is set only after a definitive
        // connect RESULT (not tied to homeLoading, which any nav clears; and not latched
        // before the load, which stranded the spinner on a transient load failure).
        if !connected {
            if account.signedIn {
                connected = true
            } else {
                guard let url = URL(string: "\(base)/auth/connect") else { return }
                var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 25
                guard let (data, _) = try? await URLSession.shared.data(for: req),
                      let res = try? JSONDecoder().decode(ConnectResult.self, from: data) else { return }  // request failed → retry
                connected = true
                if res.signedIn { await fetchAccount() }   // → reactive loadVideos (personalized)
            }
        }
        // (2) Ensure the first feed actually loads — retry every poll until it succeeds
        // (loadVideos clears homeLoading only on success), independent of session adoption.
        if homeLoading { await loadVideos() }
    }

    func fetchAccount() async {
        guard let url = URL(string: "\(base)/api/account") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let a = try JSONDecoder().decode(Account.self, from: data)
            let wasSignedIn = account.signedIn
            if a != account { account = a }
            if a.signedIn && device != nil { device = nil }        // sign-in completed
            if a.signedIn != wasSignedIn { await loadVideos() }     // swap home feed ↔ catalog
        } catch { logDecodeFailure("account", error) }
    }

    /// A schema mismatch is a bug, not an outage — surface it instead of letting the
    /// UI go silently blank. Transport errors stay quiet (the 2s poll self-heals).
    nonisolated func logDecodeFailure(_ endpoint: String, _ error: Error) {
        guard error is DecodingError else { return }
        print("[decode] \(endpoint): \(error)")
        MTDebug.log("[decode] \(endpoint): \(error)")
    }

    /// Decode large payloads OFF the main actor (a nonisolated async function runs
    /// on the concurrent executor) — the feed/watch/comments JSON blobs were being
    /// decoded on the UI thread. Logs schema mismatches; returns nil on failure.
    nonisolated func decodeOffMain<T: Decodable & Sendable>(_ type: T.Type, from data: Data, endpoint: String) async -> T? {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { logDecodeFailure(endpoint, error); return nil }
    }

    /// Sign in by reading the existing YouTube login from Firefox (no setup, no code).
    func signIn() {
        device = DeviceInfo(userCode: "", verificationURL: "", status: "connecting")
        guard let url = URL(string: "\(base)/auth/connect") else { device = nil; return }
        Task {
            var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 30
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let res = try? JSONDecoder().decode(ConnectResult.self, from: data) {
                if res.signedIn {
                    await fetchAccount()
                    device = nil
                } else {
                    device = DeviceInfo(userCode: "", verificationURL: "", status: res.error ?? "error")
                }
            } else {
                device = DeviceInfo(userCode: "", verificationURL: "", status: "error")
            }
        }
    }

    func cancelSignIn() { device = nil }

    /// Logo tap: go to (and refresh) the home feed from anywhere.
    func goHome() {
        watchVideoId = nil; watchInfo = nil; fullscreen = false; searchQuery = ""
        channelId = nil; channelInfo = nil; feedMode = "home"; playlists = nil; shortsFeed = nil
        Task { await loadVideos() }
    }

    /// Sidebar "Subscriptions": chronological new uploads from subscribed channels.
    func openSubscriptions() {
        clearNav(); feedMode = "subscriptions"; videos = []; feedContinuation = nil
        Task { await loadVideos() }
    }

    /// Sidebar "History": watched videos (FEhistory).
    func openHistory() {
        clearNav(); feedMode = "history"; videos = []; feedContinuation = nil
        Task { await loadVideos() }
    }

    /// Sidebar "Playlists": the grid of saved playlists (tap a card → detail).
    func openPlaylists() {
        clearNav()
        Task { playlists = await fetchPlaylists() }
    }

    /// One playlist's videos. id = WL (Watch Later) | LL (Liked) | PL… .
    func openPlaylist(_ id: String, title: String, fromGrid: Bool = false) {
        clearNav()
        playlistId = id; playlistTitle = title; playlistFromGrid = fromGrid
        feedMode = "playlist"; videos = []; feedContinuation = nil
        Task { await loadVideos() }
    }
    func openWatchLater() { openPlaylist("WL", title: "Watch later") }
    func openLiked() { openPlaylist("LL", title: "Liked videos") }

    /// Sidebar "Shorts": grid of shorts (tap → plays in the watch page).
    func openShorts() {
        clearNav()
        Task {
            guard let url = URL(string: "\(base)/api/shorts"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let list = try? JSONDecoder().decode([ShortItem].self, from: data) else { shortsFeed = []; return }
            shortsFeed = list
        }
    }

    /// Reset every "which page is showing" flag before opening a new destination.
    private func clearNav() {
        watchVideoId = nil; watchInfo = nil; fullscreen = false; searchQuery = ""
        channelId = nil; channelInfo = nil; playlists = nil; shortsFeed = nil; feedMode = "home"
    }

    @Published var notifications: [AppNotification] = []

    /// "Your channel" / "Your videos" → open the signed-in user's own channel page.
    func openMyChannel() {
        Task {
            struct Me: Codable { let channelId: String }
            guard let url = URL(string: "\(base)/api/me"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let me = try? JSONDecoder().decode(Me.self, from: data) else { return }
            openChannel(me.channelId)
        }
    }

    /// Load the notifications inbox (bell).
    func loadNotifications() {
        Task {
            guard let url = URL(string: "\(base)/api/notifications"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let list = try? JSONDecoder().decode([AppNotification].self, from: data) else { return }
            notifications = list
        }
    }

    private func fetchPlaylists() async -> [Playlist] {
        guard let url = URL(string: "\(base)/api/playlists") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode([Playlist].self, from: data)
        } catch { logDecodeFailure("playlists", error); return [] }
    }

    /// Title shown above the grid for non-home feeds (nil → home shows chips instead).
    var feedHeading: String? {
        switch feedMode {
        case "subscriptions": return "Subscriptions"
        case "history": return "History"
        case "playlist": return playlistTitle
        default: return nil
        }
    }

    /// Header back button, in stack order.
    func goBack() {
        if watchVideoId != nil { closeWatch() }
        else if channelId != nil { closeChannel() }
        else if shortsFeed != nil { goHome() }
        else if feedMode == "playlist" && playlistFromGrid { openPlaylists() }  // detail → grid
        else if playlists != nil { goHome() }
        else if feedMode != "home" { goHome() }
        else if !searchQuery.isEmpty { clearSearch() }
    }

    /// The sidebar item that matches what's actually on screen (drives the highlight, so it
    /// stays correct no matter how navigation happened — logo, back, a card's channel tap, etc.).
    /// For a channel page it returns the channel id, so a subscription row highlights when open.
    var currentSection: String {
        if let cid = channelId { return cid }
        if shortsFeed != nil { return "Shorts" }
        if playlists != nil { return "Playlists" }
        if !searchQuery.isEmpty { return "search" }
        switch feedMode {
        case "subscriptions": return "Subscriptions"
        case "history": return "History"
        case "playlist":
            switch playlistId {
            case "WL": return "Watch later"
            case "LL": return "Liked videos"
            default: return "Playlists"
            }
        default: return "Home"
        }
    }

    /// Should the header show a back button? (Any sub-page off the home feed.)
    var canGoBack: Bool {
        watchVideoId != nil || channelId != nil || playlists != nil || shortsFeed != nil
            || feedMode != "home" || !searchQuery.isEmpty
    }

    /// Open a channel page (from a subscription row, the watch page, etc.). The
    /// channel's uploads replace the feed grid; continuous scroll reuses /api/feed/more.
    func openChannel(_ id: String) {
        guard !id.isEmpty else { return }
        watchVideoId = nil; watchInfo = nil; fullscreen = false; searchQuery = ""
        channelId = id; channelInfo = nil; videos = []; feedContinuation = nil
        Task { [id] in
            let info = await fetchChannel(id)
            guard channelId == id else { return }   // ignore if user navigated away
            if let info {
                channelInfo = info
                videos = info.videos
                feedContinuation = info.continuation
            }
        }
    }

    func closeChannel() {
        channelId = nil; channelInfo = nil
        Task { await loadVideos() }
    }

    private func fetchChannel(_ id: String) async -> ChannelInfo? {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base)/api/channel/\(encoded)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(ChannelInfo.self, from: data)
        } catch { logDecodeFailure("channel", error); return nil }
    }

    @Published var comments: [Comment] = []
    @Published var loadingComments = false
    private var commentsContinuation: String?

    func openWatch(_ id: String) {
        watchVideoId = id
        watchInfo = nil
        comments = []; commentsContinuation = nil
        playback.height = 0; playback.enhanceActive = false; playback.hdr = false   // reset the quality readout for the new video
        Task { [id] in
            let info = await fetchWatch(id)
            if watchVideoId == id {
                watchInfo = info
                comments = info?.comments ?? []
                commentsContinuation = info?.commentsContinuation
            }
        }
    }

    /// Next page of comments (continuous scroll on the watch page).
    func loadMoreComments() async {
        guard !loadingComments, let token = commentsContinuation,
              let url = URL(string: "\(base)/api/comments/more") else { return }
        loadingComments = true
        defer { loadingComments = false }
        struct Page: Codable { let comments: [Comment]; let continuation: String? }
        let forVideo = watchVideoId   // guard against a mid-flight video switch
        do {
            var req = URLRequest(url: url); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["continuation": token])
            let (data, _) = try await URLSession.shared.data(for: req)
            guard watchVideoId == forVideo else { return }   // stale page: user moved on
            guard let page = await decodeOffMain(Page.self, from: data, endpoint: "comments/more") else { return }
            guard watchVideoId == forVideo else { return }   // re-check after the decode hop
            let seen = Set(comments.map(\.id))
            comments.append(contentsOf: page.comments.filter { !seen.contains($0.id) })
            commentsContinuation = page.continuation
        } catch { logDecodeFailure("comments/more", error) }
    }

    /// Called from the player (WKWebView bridge) with the actual decoded resolution,
    /// whether the resolution-adaptive sharpen is applied, and whether the video is HDR.
    func reportEnhance(height: Int, amount: Double, hdr: Bool) {
        if playback.height != height { playback.height = height }
        let active = amount > 0
        if playback.enhanceActive != active { playback.enhanceActive = active }
        if playback.hdr != hdr { playback.hdr = hdr }
    }
    func closeWatch() { watchVideoId = nil; watchInfo = nil; fullscreen = false }
    func enterFullscreen() { fullscreen = true }
    func exitFullscreen() { fullscreen = false }
    func toggleFullscreen() { fullscreen.toggle() }

    private func fetchWatch(_ id: String) async -> WatchInfo? {
        guard let url = URL(string: "\(base)/api/watch/\(id)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return await decodeOffMain(WatchInfo.self, from: data, endpoint: "watch")
        } catch { return nil }   // transport failure (decode issues logged in the helper)
    }

    func signOut() {
        guard let url = URL(string: "\(base)/auth/logout") else { return }
        Task {
            var req = URLRequest(url: url); req.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: req)
            await fetchAccount()
        }
    }

    func openURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    func loadVideos() async {
        // The channel page owns store.videos via openChannel(); never let a feed load
        // (e.g. the reactive one on a signedIn transition) overwrite it under the header.
        guard channelId == nil else { return }
        // Which feed the grid shows, keyed by feedMode.
        let path: String
        switch feedMode {
        case "subscriptions": path = "/api/feed/subscriptions"
        case "history":       path = "/api/feed/history"
        case "playlist":      path = "/api/playlist/\(playlistId)"
        default:              path = "/api/home"
        }
        guard let url = URL(string: "\(base)\(path)") else { return }
        let mode = feedMode
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let page = await decodeOffMain(FeedPageResponse.self, from: data, endpoint: "feed") else { return }
            guard feedMode == mode, channelId == nil else { return }   // nav changed during fetch/decode
            videos = page.videos
            feedContinuation = page.continuation
            reachable = true
            homeLoading = false   // first feed is in → stop showing the loading state
        } catch { reachable = false }   // transport failure (decode issues logged in helper)
    }

    /// Search YouTube; results replace the feed until cleared.
    func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        // Leave any other page + clear the previous feed's continuation so a scroll during
        // the fetch window can't POST a browse token to /api/search/more.
        channelId = nil; channelInfo = nil; playlists = nil; shortsFeed = nil; watchVideoId = nil; feedMode = "home"
        searchQuery = q
        videos = []; feedContinuation = nil
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        guard let url = URL(string: "\(base)/api/search?q=\(encoded)") else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let page = await decodeOffMain(FeedPageResponse.self, from: data, endpoint: "search") else { return }
                guard searchQuery == q else { return }   // ignore stale search
                videos = page.videos
                feedContinuation = page.continuation
            } catch { /* transport failure */ }
        }
    }

    func clearSearch() {
        searchQuery = ""
        Task { await loadVideos() }
    }

    /// Load the next page (continuous scroll) — home feed or search results. De-dupes by id.
    func loadMore() async {
        let path = searchQuery.isEmpty ? "/api/feed/more" : "/api/search/more"
        guard !loadingMore, let token = feedContinuation,
              let url = URL(string: "\(base)\(path)") else { return }
        loadingMore = true
        defer { loadingMore = false }
        // Snapshot the navigation context: a page that returns after the user
        // switched feed/search/channel must not be appended into the new grid.
        let ctx = (feedMode, searchQuery, channelId)
        do {
            var req = URLRequest(url: url); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["continuation": token])
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let page = await decodeOffMain(FeedPageResponse.self, from: data, endpoint: "feed/more") else { return }
            guard ctx == (feedMode, searchQuery, channelId) else { return }   // stale page
            // History and playlists may legitimately list the same video more than once;
            // only de-dupe feeds where a repeat is spurious (home / subscriptions / search).
            if feedMode == "history" || feedMode == "playlist" {
                videos.append(contentsOf: page.videos)
            } else {
                let seen = Set(videos.map(\.id))
                videos.append(contentsOf: page.videos.filter { !seen.contains($0.id) })
            }
            feedContinuation = page.continuation
        } catch { logDecodeFailure("feed/more", error) }
    }

    /// Build the HDR tab: HDR videos from the CHANNELS in the current suggestions,
    /// backed by YouTube's own HDR search filter, seeded with the channel NAMES that appear
    /// in the user's suggestions (their HDR uploads + related HDR content). Skips if the seed
    /// set is unchanged since the last load.
    func loadHDR(force: Bool = false) async {
        var seen = Set<String>()
        let names = videos.map { $0.channel }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let key = names.joined(separator: ",")
        guard force || key != hdrProbedKey,
              let url = URL(string: "\(base)/api/hdr") else { return }
        hdrLoading = true
        defer { hdrLoading = false }
        struct Body: Encodable { let queries: [String] }
        do {
            var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 120
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(Body(queries: names))
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let r = await decodeOffMain(FeedPageResponse.self, from: data, endpoint: "hdr") else { return }
            hdrVideos = r.videos
            hdrProbedKey = key
        } catch { /* keep any prior HDR set */ }
    }

    /// Log a watched video to the signed-in account's YouTube history — fire-and-forget,
    /// once per video per session. Called by the WebPlayer once real playback passes the
    /// watched threshold; the backend fires YouTube's own videostats ping.
    private var markedWatched = Set<String>()
    func markWatched(_ videoId: String) {
        guard !videoId.isEmpty, markedWatched.insert(videoId).inserted,
              let url = URL(string: "\(base)/api/markWatched") else { return }
        Task {
            var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(["videoId": videoId])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Set the GPU enhance preset ("off" | "subtle" | "sharper"). Optimistic: updates
    /// local settings immediately (the WebPlayer re-reads the flag within ~1s), then PATCHes.
    func setEnhance(_ value: String) {
        guard ["off", "subtle", "sharper"].contains(value) else { return }
        settings.enhance = value
        Task { await patchSettings("{\"enhance\":\"\(value)\"}") }
    }

    func setMaxResolution(_ on: Bool) {
        settings.maxResolution = on
        Task { await patchSettings("{\"maxResolution\":\(on)}") }
    }

    func setTheater(_ on: Bool) {
        settings.theaterMode = on
        Task { await patchSettings("{\"theaterMode\":\(on)}") }
    }

    func setAdBlock(_ on: Bool) {
        settings.adBlock = on
        Task { await patchSettings("{\"adBlock\":\(on)}") }
    }

    func setSponsorBlock(_ on: Bool) {
        settings.sponsorBlock = on
        Task { await patchSettings("{\"sponsorBlock\":\(on)}") }
    }

    func setDeArrow(_ on: Bool) {
        settings.deArrow = on
        Task { await patchSettings("{\"deArrow\":\(on)}") }
    }

    /// Theme is validated server-side to "dark"|"light"; guard here too.
    func setTheme(_ value: String) {
        guard value == "dark" || value == "light" else { return }
        settings.theme = value
        Task { await patchSettings("{\"theme\":\"\(value)\"}") }
    }

    /// Player rate. Backend clamps to 0.25...3.0; the UI offers 1/1.25/1.5/1.75/2.
    func setPlaybackSpeed(_ value: Double) {
        let v = min(max(value, 0.25), 3.0)
        settings.playbackSpeed = v
        Task { await patchSettings("{\"playbackSpeed\":\(v)}") }
    }

    func setAutoFullscreen(_ on: Bool) {
        settings.autoFullscreen = on
        Task { await patchSettings("{\"autoFullscreen\":\(on)}") }
    }

    // MARK: - Account write actions (real subscribe / like)

    private struct ActionResult: Decodable { let ok: Bool }

    /// Subscribe / unsubscribe on the real account. Returns true on success (for optimistic revert).
    func setSubscription(channelId: String, on: Bool) async -> Bool {
        struct Body: Encodable { let channelId: String; let subscribe: Bool }
        return await postAction("/api/subscribe", Body(channelId: channelId, subscribe: on))
    }

    /// Set the real like state: "like" | "dislike" | "none". Returns true on success.
    func setLike(videoId: String, state: String) async -> Bool {
        struct Body: Encodable { let videoId: String; let state: String }
        return await postAction("/api/like", Body(videoId: videoId, state: state))
    }

    private func postAction<B: Encodable>(_ path: String, _ body: B) async -> Bool {
        guard let url = URL(string: "\(base)\(path)") else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let r = try? JSONDecoder().decode(ActionResult.self, from: data) else { return false }
        return r.ok
    }

    private func patchSettings(_ json: String) async {
        guard let url = URL(string: "\(base)/api/settings") else { return }
        var req = URLRequest(url: url); req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json.data(using: .utf8)
        _ = try? await URLSession.shared.data(for: req)   // 2s poll reconciles authoritative state
    }

    func fetchSettings() async {
        guard let url = URL(string: "\(base)/api/settings") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let s = try JSONDecoder().decode(Settings.self, from: data)
            reachable = true
            if s != settings {
                print("[MiniTube] settings changed -> adBlock=\(s.adBlock) sponsorBlock=\(s.sponsorBlock) deArrow=\(s.deArrow) theater=\(s.theaterMode) speed=\(s.playbackSpeed) theme=\(s.theme)")
                settings = s
            }
        } catch {
            logDecodeFailure("settings", error)
            if !(error is DecodingError) { reachable = false }
        }
    }

    func detail(_ id: String) async -> VideoDetail? {
        guard let url = URL(string: "\(base)/api/videos/\(id)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(VideoDetail.self, from: data)
        } catch { logDecodeFailure("detail", error); return nil }
    }

    func embedURL(_ id: String) -> String { "\(base)/embed?v=\(id)" }

    // Title/thumbnail resolved against the current DeArrow toggle.
    func title(for v: VideoListItem) -> String {
        (settings.deArrow ? v.deArrowTitle : nil) ?? v.originalTitle
    }
    func thumbnail(for v: VideoListItem) -> String {
        (settings.deArrow ? v.deArrowThumbnail : nil) ?? v.originalThumbnail
    }
    func isDeArrowed(_ v: VideoListItem) -> Bool { settings.deArrow && v.deArrowTitle != nil }
    func hasSponsor(_ v: VideoListItem) -> Bool { v.hasSponsorSegments ?? false }

    func durationLabel(for v: VideoListItem) -> String? {
        guard let secs = v.durationSeconds, secs > 0 else { return nil }
        let total = Int(secs.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Distinct channels in catalog order — powers the sidebar "Subscriptions" list.
    var subscriptions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for v in videos where seen.insert(v.channel).inserted { out.append(v.channel) }
        return out
    }
}
