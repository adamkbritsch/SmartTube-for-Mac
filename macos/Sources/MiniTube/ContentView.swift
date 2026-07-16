import SwiftUI
import AppKit

/// Hand (pointer) cursor on hover. Balanced push/pop with a `pushed` guard + a pop on
/// disappear — because SwiftUI does NOT deliver onHover(false) when a hovered view is
/// destroyed (e.g. a card tap swaps the whole grid), which would otherwise leak the
/// cursor onto the global stack and make the pointing hand stick app-wide.
private struct ClickCursor: ViewModifier {
    @State private var pushed = false
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}
extension View {
    /// Pointer cursor on hover — apply to every interactive control (macOS shows the arrow by default).
    func clickable() -> some View { modifier(ClickCursor()) }
}

/// Subtle tactile press feedback for large tap targets (cards, rows).
struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Theme helpers

func themeBackground(_ theme: String) -> Color {
    theme == "dark" ? Color(red: 0.06, green: 0.06, blue: 0.06) : Color(red: 0.97, green: 0.97, blue: 0.97)
}
func channelColor(_ name: String) -> Color {
    let palette: [Color] = [.red, .orange, .pink, .purple, .blue, .teal, .green, .indigo]
    return palette[abs(name.hashValue) % palette.count]
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var selectedChip = "All"
    @State private var selectedSidebar = "Home"
    @State private var sidebarCollapsed = false
    @State private var showExtSettings = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderBar(search: $search, sidebarCollapsed: $sidebarCollapsed, showExtSettings: $showExtSettings, showSettings: $showSettings)
                Divider().opacity(0.4)
                ZStack {
                    // Browse layer stays mounted while watching so feed scroll/position survives a round-trip.
                    HStack(spacing: 0) {
                        SidebarView(selected: $selectedSidebar, collapsed: sidebarCollapsed)
                            .frame(width: sidebarCollapsed ? 76 : 240)
                        Divider().opacity(0.35)
                        // Measure the content area once → drives every grid's column count.
                        GeometryReader { geo in
                            Group {
                                if store.playlists != nil {
                                    PlaylistsView().environmentObject(store)
                                } else if store.shortsFeed != nil {
                                    ShortsView().environmentObject(store)
                                } else if store.channelId != nil {
                                    ChannelView().environmentObject(store)
                                } else {
                                    FeedView(search: search, selectedChip: $selectedChip)
                                }
                            }
                            .environment(\.gridContentWidth, geo.size.width)
                        }
                    }
                    if let id = store.watchVideoId {
                        WatchPage(videoId: id).environmentObject(store)   // overlays browse layer; no sidebar
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(themeBackground(store.settings.theme))
                    }
                }
            }
            .background(themeBackground(store.settings.theme))
            .sheet(isPresented: $showExtSettings) {
                ExtensionSettingsSheet().environmentObject(store)
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet().environmentObject(store)
            }
        }
        .preferredColorScheme(store.settings.theme == "dark" ? .dark : .light)
        .frame(minWidth: 940, minHeight: 580)
        .onAppear {
            // Debug hook: `touch /tmp/mt-open-ext` before launch auto-opens the
            // extension-settings sheet so the load path can be tested headlessly.
            if FileManager.default.fileExists(atPath: "/tmp/mt-open-ext") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { showExtSettings = true }
            }
            // Debug hook: write a video id to /tmp/mt-open-watch to auto-open it, so
            // the ad-prune path can be exercised headlessly.
            if let id = try? String(contentsOfFile: "/tmp/mt-open-watch", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { store.openWatch(id) }
            }
        }
        .sheet(item: $store.device) { info in
            DeviceSignInSheet(info: info).environmentObject(store)
        }
    }
}

/// Live resolution + HDR badges. Isolated so only THIS view re-renders on the
/// player's per-second readout ticks (see PlaybackState).
private struct PlaybackReadout: View {
    @ObservedObject var playback: PlaybackState

    var body: some View {
        HStack(spacing: 10) {
            if !resLabel.isEmpty {
                Text(resLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .help("Playing resolution")
            }
            if playback.hdr {
                Text("HDR").font(.system(size: 10, weight: .heavy))
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(LinearGradient(
                        colors: [Color(red: 1, green: 0.58, blue: 0), Color(red: 1, green: 0.24, blue: 0.42)],
                        startPoint: .leading, endPoint: .trailing)))
                    .foregroundStyle(.white)
                    .help("This video is playing in real HDR (native, via macOS EDR)")
            }
        }
    }

    // Decoded height only — Enhance state is no longer surfaced here (it lives in Settings).
    private var resLabel: String {
        let h = playback.height
        guard h > 0 else { return "" }
        switch h {
        case 4320...: return "8K"
        case 2160...: return "4K"
        default:      return "\(h)p"
        }
    }
}

// MARK: - Watch page (single real-YouTube player; YouTube's own fullscreen)

struct WatchPage: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var gpuSaver = GPUSaver.shared
    let videoId: String
    @State private var selectedChip = "All"
    @State private var autoplay = true
    @State private var descExpanded = false
    // Engagement state (backed by real account writes via the backend).
    @State private var subscribed = false
    @State private var likeState = 0          // -1 dislike, 0 none, 1 like
    @State private var shareCopied = false
    @State private var seededVideoId = ""     // metadata state applied once per video
    @State private var likeWritesInFlight = 0
    @State private var subscribeWritesInFlight = 0

    private var info: WatchInfo? { store.watchInfo?.videoId == videoId ? store.watchInfo : nil }

    // Up-next filter: "From <channel>" narrows to the uploader; "All" shows everything.
    private var filteredRecs: [VideoListItem] {
        let recs = info?.recommendations ?? []
        if selectedChip.hasPrefix("From "), let ch = info?.channel, !ch.isEmpty {
            let same = recs.filter { $0.channel == ch }
            return same.isEmpty ? recs : same
        }
        return recs
    }

    // The channel filter is only meaningful when the recs mix this channel with others.
    private var channelFilterUseful: Bool {
        guard let ch = info?.channel, !ch.isEmpty else { return false }
        let recs = info?.recommendations ?? []
        return recs.contains { $0.channel == ch } && recs.contains { $0.channel != ch }
    }

    // Single real-YouTube player. Its own controls (incl. fullscreen) handle everything.
    private var playerSlot: some View {
        WebPlayer(videoId: videoId, adBlock: store.settings.adBlock, sponsorBlock: store.settings.sponsorBlock,
                  maxResolution: store.settings.maxResolution, enhance: store.settings.enhance,
                  gpuSaver: gpuSaver.active, playbackSpeed: store.settings.playbackSpeed,
                  autoFullscreen: store.settings.autoFullscreen,
                  onEnhanceInfo: { h, a, hdr in Task { @MainActor in store.reportEnhance(height: h, amount: a, hdr: hdr) } },
                  onEnded: {
                      // Autoplay: the toggle in the up-next rail now actually does something.
                      Task { @MainActor in
                          if autoplay, let next = filteredRecs.first { store.openWatch(next.id) }
                      }
                  },
                  onTheater: {
                      // YouTube's in-player theater button → the app's theater (widen).
                      Task { @MainActor in store.setTheater(!store.settings.theaterMode) }
                  },
                  onMarkWatched: { vid in
                      // Watched past the threshold → log the view to YouTube history.
                      Task { @MainActor in store.markWatched(vid) }
                  })
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    playerSlot
                    playerBar

                    Text(info?.title ?? "Loading…")
                        .font(.title2.bold()).lineLimit(3).textSelection(.enabled)

                    channelRow
                    descriptionBox
                    commentsSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !store.settings.theaterMode {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Up next").font(.headline)
                        Spacer()
                        Text("Autoplay").font(.caption).foregroundStyle(.secondary)
                        Toggle("", isOn: $autoplay).labelsHidden().toggleStyle(.switch).controlSize(.mini).clickable()
                    }
                    // Only show the All / From-channel filter when it would actually change the
                    // list — i.e. the recs are a mix of this channel and others. If every rec is
                    // from the uploader (or none are), the filter is a no-op, so hide it.
                    if channelFilterUseful, let ch = info?.channel {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                recChip("All")
                                recChip("From \(ch)")
                            }
                        }
                    }
                    ForEach(filteredRecs) { rec in
                        Button { store.openWatch(rec.id) } label: { RecRow(video: rec) }
                            .buttonStyle(CardPress()).clickable()
                    }
                }
                .padding(.vertical, 20).padding(.trailing, 20).padding(.leading, 4)
            }
            .frame(width: 402)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.settings.theaterMode)
        .onChange(of: videoId) { _, _ in
            subscribed = false; likeState = 0; shareCopied = false; selectedChip = "All"; descExpanded = false
        }
        .onAppear { seedEngagement() }
        .onChange(of: store.watchInfo?.videoId) { _, _ in seedEngagement() }
    }

    /// Reflect the real subscribed / like state once this video's metadata arrives.
    /// Seeds at most once per video, and never over a user tap that's still in
    /// flight — the server snapshot predates the tap and would undo it.
    private func seedEngagement() {
        guard let i = info, seededVideoId != videoId else { return }
        seededVideoId = videoId
        if subscribeWritesInFlight == 0 { subscribed = i.subscribed ?? false }
        if likeWritesInFlight == 0 { likeState = i.likeStatus ?? 0 }
    }

    // Under-player bar: live resolution/HDR readout, plus theater + max-quality quick toggles.
    // (Enhance moved to Settings — it isn't shown here.) The readout is isolated in its own
    // PlaybackReadout so WatchPage doesn't re-render on the per-second ticks.
    private var playerBar: some View {
        HStack(spacing: 10) {
            PlaybackReadout(playback: store.playback)

            Spacer(minLength: 8)

            Button { store.setTheater(!store.settings.theaterMode) } label: {
                Image(systemName: store.settings.theaterMode ? "rectangle.inset.filled" : "rectangle")
                    .font(.system(size: 13))
                    .padding(.horizontal, 11).frame(height: 30)
                    .foregroundStyle(store.settings.theaterMode ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary))
                    .background(Capsule().fill(store.settings.theaterMode ? accent.opacity(0.15) : Color.primary.opacity(0.08)))
                    .contentShape(Rectangle())   // whole capsule tappable — a hollow icon glyph alone isn't
            }
            .buttonStyle(.plain).clickable()
            .help("Theater mode — hide the up-next rail and widen the player")

            Button { store.setMaxResolution(!store.settings.maxResolution) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "4k.tv").font(.system(size: 12))
                    Text("Max quality").font(.system(size: 12, weight: .medium))
                    Image(systemName: store.settings.maxResolution ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 12).frame(height: 30)
                .foregroundStyle(store.settings.maxResolution ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary))
                .background(Capsule().fill(store.settings.maxResolution ? accent.opacity(0.15) : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Force the highest available resolution")
        }
        .padding(.top, 2)
    }

    private var accent: Color { Color(red: 0.24, green: 0.65, blue: 1) }

    private func recChip(_ label: String) -> some View {
        let active = selectedChip == label
        return Button { selectedChip = label } label: {
            Text(label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(active ? Color.primary : Color.primary.opacity(0.1)))
                .foregroundStyle(active ? AnyShapeStyle(themeBackground(store.settings.theme)) : AnyShapeStyle(Color.primary))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text((info?.commentCount).flatMap { $0.isEmpty ? nil : $0 } ?? "Comments")
                .font(.headline).padding(.top, 4)
            ForEach(store.comments) { c in
                CommentRow(comment: c)
                    .onAppear {
                        // near the last loaded comment → pull the next page
                        if c.id == store.comments.last?.id { Task { await store.loadMoreComments() } }
                    }
            }
            if store.loadingComments {
                ForEach(0..<3, id: \.self) { _ in SkeletonCommentRow() }
            }
        }
    }

    private var channelRow: some View {
        HStack(spacing: 12) {
            Button {
                if let id = info?.channelId, !id.isEmpty { store.openChannel(id) }
            } label: {
                HStack(spacing: 12) {
                    AvatarView(url: nil, name: info?.channel ?? "?", size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(info?.channel ?? " ").font(.system(size: 15, weight: .semibold))
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(info?.subscribers ?? " ").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { applySubscribe() } label: {
                Text(subscribed ? "Subscribed" : "Subscribe")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(Capsule().fill(subscribed ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(Color.primary)))
                    .foregroundStyle(subscribed ? AnyShapeStyle(Color.primary) : AnyShapeStyle(themeBackground(store.settings.theme)))
            }
            .buttonStyle(.plain).clickable()
            .disabled((info?.channelId ?? "").isEmpty)
            Spacer()
            // Joined like | dislike control (matches YouTube) — writes to the real account.
            HStack(spacing: 0) {
                Button { applyLike(1) } label: {
                    Label(info?.likes ?? "", systemImage: likeState == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(height: 36)
                        .foregroundStyle(likeState == 1 ? AnyShapeStyle(accent) : AnyShapeStyle(Color.primary))
                }.buttonStyle(.plain).clickable()
                Divider().frame(height: 18).opacity(0.4)
                Button { applyLike(-1) } label: {
                    Image(systemName: likeState == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).frame(height: 36)
                        .foregroundStyle(likeState == -1 ? AnyShapeStyle(accent) : AnyShapeStyle(Color.primary))
                }.buttonStyle(.plain).clickable()
            }
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            Button { copyShareURL() } label: {
                Label(shareCopied ? "Copied!" : "Share",
                      systemImage: shareCopied ? "checkmark" : "arrowshape.turn.up.right")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }.buttonStyle(.plain).clickable()
        }
    }

    // Real account write: subscribe / unsubscribe. Optimistic, reverts on failure —
    // but only onto the SAME video's UI: a late failure for video A must not
    // clobber video B's state after the user navigates (WatchPage is reused).
    private func applySubscribe() {
        guard let cid = info?.channelId, !cid.isEmpty else { return }
        let old = subscribed
        let newVal = !subscribed
        let forVideo = videoId
        subscribeWritesInFlight += 1
        withAnimation(.easeOut(duration: 0.12)) { subscribed = newVal }
        Task {
            let ok = await store.setSubscription(channelId: cid, on: newVal)
            await MainActor.run {
                subscribeWritesInFlight -= 1
                guard !ok, store.watchVideoId == forVideo else { return }
                withAnimation(.easeOut(duration: 0.2)) { subscribed = old }
            }
        }
    }

    // Real account write: like / dislike / clear. `target` is 1 (like) or -1 (dislike).
    private func applyLike(_ target: Int) {
        let old = likeState
        let newState = likeState == target ? 0 : target
        let forVideo = videoId
        likeWritesInFlight += 1
        withAnimation(.easeOut(duration: 0.12)) { likeState = newState }
        let action = newState == 1 ? "like" : (newState == -1 ? "dislike" : "none")
        Task {
            let ok = await store.setLike(videoId: forVideo, state: action)
            await MainActor.run {
                likeWritesInFlight -= 1
                guard !ok, store.watchVideoId == forVideo else { return }
                withAnimation(.easeOut(duration: 0.2)) { likeState = old }
            }
        }
    }

    // Real, side-effect-free: put the canonical watch URL on the clipboard.
    private func copyShareURL() {
        let url = "https://www.youtube.com/watch?v=\(videoId)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { shareCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { shareCopied = false } }
        }
    }

    // Hidden entirely until it has something to show — otherwise it's an empty gray card that
    // flashes on every video open (info arrives async) and lingers for videos with no stats/desc.
    @ViewBuilder private var descriptionBox: some View {
        let views = (info?.views ?? "")
        let published = (info?.published ?? "")
        let desc = (info?.description ?? "")
        if !views.isEmpty || !published.isEmpty || !desc.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if !views.isEmpty { Text(views).font(.system(size: 13, weight: .semibold)) }
                    if !published.isEmpty { Text(published).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
                }
                if !desc.isEmpty {
                    Text(desc).font(.system(size: 13)).textSelection(.enabled)
                        .lineLimit(descExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(descExpanded ? "Show less" : "…more") {
                        withAnimation(.easeInOut(duration: 0.15)) { descExpanded.toggle() }
                    }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).clickable()
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct RecRow: View {
    @EnvironmentObject var store: Store
    let video: VideoListItem
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                CachedImage(url: video.originalThumbnail) { Rectangle().fill(Color.primary.opacity(0.12)) }
                .frame(width: 168, height: 94).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                if let d = store.durationLabel(for: video) {
                    Text(d).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.black.opacity(0.8)).foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(video.originalTitle).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(video.channel).font(.system(size: 12)).foregroundStyle(.secondary)
                Text([video.viewCountText, video.publishedText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .clickable()
    }
}

// MARK: - Device-code sign-in sheet

struct DeviceSignInSheet: View {
    @EnvironmentObject var store: Store
    let info: DeviceInfo

    private var status: String { store.device?.status ?? info.status }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) { LogoMark(); Text("Sign in to YouTube").font(.title3.bold()) }

            switch status {
            case "connecting":
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to your YouTube session in Firefox…")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            case "no_session":
                message("person.crop.circle.badge.exclamationmark",
                        "Not signed into YouTube in Firefox",
                        "Open YouTube in Firefox and sign in, then try again. This app uses that existing login — no code or setup needed.")
                HStack(spacing: 10) {
                    Button("Open YouTube") { store.openURL("https://www.youtube.com") }
                    Button("Try again") { store.signIn() }.buttonStyle(.borderedProminent)
                }
            default: // error
                message("xmark.circle.fill", "Couldn't connect",
                        "Something went wrong reading your Firefox YouTube session. Make sure you're logged in at youtube.com in Firefox, then try again.")
                Button("Try again") { store.signIn() }.buttonStyle(.borderedProminent)
            }

            Button("Cancel") { store.cancelSignIn() }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 430)
    }

    private func message(_ symbol: String, _ title: String, _ body: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(body).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Header

/// Header icon button with a hover highlight + pointer cursor (macOS gives neither by default).
private struct HeaderIconButton: View {
    let symbol: String
    var size: CGFloat = 17
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .regular))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain).contentShape(Circle()).help(help)
        .onHover { hover = $0 }
        .clickable()
    }
}

private struct HeaderBar: View {
    @EnvironmentObject var store: Store
    @Binding var search: String
    @Binding var sidebarCollapsed: Bool
    @Binding var showExtSettings: Bool
    @Binding var showSettings: Bool
    @State private var showNotifications = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            HeaderIconButton(symbol: "line.3.horizontal", help: "Menu") {
                withAnimation(.easeInOut(duration: 0.2)) { sidebarCollapsed.toggle() }
            }
            if store.canGoBack {
                HeaderIconButton(symbol: "chevron.left", size: 16, help: "Back") { store.goBack() }
            }
            Button { store.goHome() } label: {
                BrandLogo(height: 26)
            }
            .buttonStyle(.plain).help("Home").clickable()
            Spacer(minLength: 12)
            searchField
            Spacer(minLength: 12)
            HeaderIconButton(symbol: "gearshape", size: 16, help: "Settings") {
                showSettings = true
            }
            HeaderIconButton(symbol: "puzzlepiece.extension", size: 16, help: "uBlock Origin Lite & SponsorBlock settings") {
                showExtSettings = true
            }
            HeaderIconButton(symbol: "bell", help: "Notifications") {
                showNotifications.toggle()
                if showNotifications { store.loadNotifications() }
            }
            .popover(isPresented: $showNotifications, arrowEdge: .bottom) {
                NotificationsPanel(dismiss: { showNotifications = false }).environmentObject(store)
            }
            accountView
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
        .background(keyboardShortcuts)
    }

    // Invisible controls that carry the app's keyboard shortcuts.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { if store.canGoBack { store.goBack() } }.keyboardShortcut("[", modifiers: .command)
            Button("") { if store.canGoBack { store.goBack() } }.keyboardShortcut(.leftArrow, modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    @ViewBuilder private var accountView: some View {
        if store.account.signedIn, let p = store.account.profile {
            Menu {
                Text(p.name)
                Text(p.email)
                Divider()
                Button("Sign out") { store.signOut() }
            } label: {
                avatarImage(p.picture)
            }
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .help(p.name)
        } else {
            Button { store.signIn() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle").font(.system(size: 15))
                    Text("Sign in").font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 12).frame(height: 34)
                .overlay(Capsule().stroke(Color(red: 0.24, green: 0.65, blue: 1), lineWidth: 1))
                .foregroundStyle(Color(red: 0.24, green: 0.65, blue: 1))
            }
            .buttonStyle(.plain)
            .help("Sign in with Google")
        }
    }

    private func avatarImage(_ url: String) -> some View {
        CachedImage(url: url) {
            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0, blue: 0.2), .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit { store.search(search) }
            if !search.isEmpty {
                Button { search = ""; store.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).clickable()
            }
            Button { store.search(search) } label: {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }.buttonStyle(.plain).clickable()
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .frame(maxWidth: 520)
        .background(Capsule().fill(Color.primary.opacity(searchFocused ? 0.04 : 0.08)))
        .overlay(Capsule().stroke(
            searchFocused ? Color(red: 0.24, green: 0.65, blue: 1) : Color.primary.opacity(0.12),
            lineWidth: searchFocused ? 2 : 1))
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var selected: String
    var collapsed: Bool = false
    @State private var subsExpanded = false
    private let subsCollapsedLimit = 7

    var body: some View {
        if collapsed { miniRail } else { fullSidebar }
    }

    private var miniRail: some View {
        ScrollView {
            VStack(spacing: 4) {
                miniItem("Home", "house.fill")
                miniItem("Shorts", "play.rectangle.fill")
                miniItem("Subscriptions", "play.square.stack.fill")
                miniItem("You", "person.crop.circle")
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity)
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }

    private func miniItem(_ label: String, _ symbol: String) -> some View {
        Button {
            selected = label
            if label == "Home" { store.goHome() }
            else if label == "Shorts" { store.openShorts() }
            else if label == "Subscriptions" { store.openSubscriptions() }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(label).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 10).fill(store.currentSection == label ? Color.primary.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
        .padding(.horizontal, 6)
    }

    private var fullSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row("Home", "house.fill")
                row("Shorts", "play.rectangle.fill")
                row("Subscriptions", "play.square.stack.fill")

                sectionHeader("Subscriptions", trailing: nil)
                if store.account.signedIn && !store.account.subscriptions.isEmpty {
                    let subs = store.account.subscriptions
                    let shown = subsExpanded ? subs : Array(subs.prefix(subsCollapsedLimit))
                    ForEach(shown) { channelRow(title: $0.title, thumb: $0.thumbnail, channelId: $0.channelId) }
                    if subs.count > subsCollapsedLimit { showMoreRow }
                } else {
                    let subs = store.subscriptions
                    let shown = subsExpanded ? subs : Array(subs.prefix(subsCollapsedLimit))
                    ForEach(shown, id: \.self) { channelRow(title: $0, thumb: nil, channelId: nil) }
                    if subs.count > subsCollapsedLimit { showMoreRow }
                }

                sectionHeader("You", trailing: "chevron.right")
                row("Your channel", "person.crop.square")
                row("History", "clock.arrow.circlepath")
                row("Playlists", "list.bullet.rectangle")
                row("Watch later", "clock")
                row("Liked videos", "hand.thumbsup")
                row("Your videos", "play.square")
            }
            .padding(10)
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }

    // Toggles the subscription list between the collapsed limit and the full list.
    private var showMoreRow: some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { subsExpanded.toggle() } } label: {
            HStack(spacing: 20) {
                Image(systemName: subsExpanded ? "chevron.up" : "chevron.down").font(.system(size: 16)).frame(width: 22)
                Text(subsExpanded ? "Show less" : "Show more").font(.system(size: 14))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).clickable()
    }

    private func row(_ label: String, _ symbol: String) -> some View {
        Button {
            selected = label
            switch label {
            case "Home": store.goHome()
            case "Shorts": store.openShorts()
            case "Subscriptions": store.openSubscriptions()
            case "History": store.openHistory()
            case "Playlists": store.openPlaylists()
            case "Watch later": store.openWatchLater()
            case "Liked videos": store.openLiked()
            case "Your channel", "Your videos": store.openMyChannel()
            default: break
            }
        } label: {
            HStack(spacing: 20) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 22)
                Text(label).font(.system(size: 14, weight: store.currentSection == label ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(store.currentSection == label ? Color.primary.opacity(0.12) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).clickable()
    }

    private func channelRow(title: String, thumb: String?, channelId: String?) -> some View {
        let sel = channelId != nil && store.currentSection == channelId
        return Button { if let id = channelId, !id.isEmpty { store.openChannel(id) } } label: {
            HStack(spacing: 16) {
                AvatarView(url: thumb, name: title, size: 24)
                Text(title).font(.system(size: 14, weight: sel ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(sel ? Color.primary.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
    }

    private func monogram(_ name: String) -> some View {
        Circle().fill(channelColor(name).gradient)
            .overlay(Text(String(name.prefix(1))).font(.system(size: 11, weight: .bold)).foregroundColor(.white))
    }


    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let trailing { Image(systemName: trailing).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
    }
}

// MARK: - Feed (chips + grid)

private struct FeedView: View {
    @EnvironmentObject var store: Store
    @Environment(\.gridContentWidth) private var gridW
    var search: String
    @Binding var selectedChip: String

    private let chips: [(String, [String])] = [
        ("All", []),
        ("Science", ["Veritasium", "Kurzgesagt"]),
        ("Education", ["MIT", "Veritasium", "Kurzgesagt"]),
        ("Challenges", ["MrBeast"]),
        ("Animation", ["Kurzgesagt", "Blender"]),
        ("Music", ["Rick Astley"]),
    ]

    private var isSearch: Bool { !store.searchQuery.isEmpty }

    private var shown: [VideoListItem] {
        if isSearch { return store.videos }        // server-side results, unfiltered
        if store.feedHeading != nil { return store.videos }   // subs/history/playlist, unfiltered
        if selectedChip == "HDR" { return store.hdrVideos }   // curated HDR + feed-personalized picks
        let keywords = chips.first { $0.0 == selectedChip }?.1 ?? []
        return store.videos.filter { v in
            keywords.isEmpty || keywords.contains { v.channel.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isSearch {
                HStack(spacing: 12) {
                    Text("Results for \u{201C}\(store.searchQuery)\u{201D}").font(.headline).lineLimit(1)
                    Spacer()
                    Button { store.clearSearch() } label: {
                        Label("Clear", systemImage: "xmark").font(.system(size: 13, weight: .medium))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            } else if let heading = store.feedHeading {
                HStack(spacing: 12) {
                    Text(heading).font(.title3.bold()).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        chip("Your custom feed", icon: "square.grid.2x2")
                        chip("HDR", icon: "sun.max.fill")
                        ForEach(chips, id: \.0) { chip($0.0, icon: nil) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
            Divider().opacity(0.3)

            ScrollView {
                if store.homeLoading && !isSearch && store.feedHeading == nil {
                    // Initial launch: skeleton grid until the personalized
                    // recommendations arrive (no seeded-catalog flash).
                    SkeletonVideoGrid()
                } else if isHDRTab && store.hdrLoading && shown.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Finding HDR videos for you…").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 140)
                } else if isHDRTab && !store.hdrLoading && shown.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "sun.max").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Couldn't reach HDR videos right now").font(.system(size: 14, weight: .medium))
                        Text("Check your connection, then select HDR again.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 120)
                } else {
                VStack(alignment: .leading, spacing: 16) {
                    if !store.reachable {
                        Label("Backend unreachable — run the Vapor server on :8080", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if !store.settings.adBlock { AdCard() }
                    LazyVGrid(columns: Grid3.videoColumns(for: gridW), spacing: 28) {
                        if store.feedMode == "history" || store.feedMode == "playlist" {
                            // Per-position identity: these feeds may legitimately repeat a video.
                            ForEach(Array(shown.enumerated()), id: \.offset) { idx, v in
                                Button { store.openWatch(v.id) } label: { VideoCard(video: v) }
                                    .buttonStyle(CardPress())
                                    .onAppear {
                                        if idx == shown.count - 1 { Task { await store.loadMore() } }
                                    }
                            }
                        } else {
                            // Stable video-id identity: chip switches / search swaps must NOT
                            // recycle a card's @State + image onto a different video.
                            ForEach(shown) { v in
                                Button { store.openWatch(v.id) } label: { VideoCard(video: v) }
                                    .buttonStyle(CardPress())
                                    .onAppear {
                                        if v.id == shown.last?.id { Task { await store.loadMore() } }
                                    }
                            }
                        }
                    }
                    if store.loadingMore {
                        SkeletonVideoRow()
                    }
                }
                .padding(20)
                }   // end else (not homeLoading)
            }
        }
        .background(themeBackground(store.settings.theme))
        // Probe for HDR when the HDR chip is picked, and again as the feed grows.
        .onChange(of: selectedChip) { _, v in if v == "HDR" { Task { await store.loadHDR() } } }
        .onChange(of: store.videos.count) { _, _ in if selectedChip == "HDR" { Task { await store.loadHDR() } } }
    }

    private var isHDRTab: Bool { selectedChip == "HDR" && !isSearch && store.feedHeading == nil }

    private func chip(_ label: String, icon: String?) -> some View {
        let active = selectedChip == label
        return Button { selectedChip = label } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12)) }
                Text(label).font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(Capsule().fill(active ? Color.primary : Color.primary.opacity(0.1)))
            .foregroundStyle(active ? AnyShapeStyle(themeBackground(store.settings.theme)) : AnyShapeStyle(Color.primary))
        }
        .buttonStyle(.plain).clickable()
    }
}

// MARK: - Channel page

private struct ChannelView: View {
    @EnvironmentObject var store: Store
    @Environment(\.gridContentWidth) private var gridW
    @State private var subscribed = false
    @State private var seededChannel = ""
    @State private var subWritesInFlight = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                tabBar
                Divider().opacity(0.3)
                grid
            }
        }
        .background(themeBackground(store.settings.theme))
    }

    private var header: some View {
        let ch = store.channelInfo
        return HStack(alignment: .center, spacing: 24) {
            AvatarView(url: ch?.avatar, name: ch?.name ?? "?", size: 128)

            VStack(alignment: .leading, spacing: 8) {
                Text(ch?.name ?? "Loading\u{2026}").font(.system(size: 30, weight: .bold))
                HStack(spacing: 6) {
                    if let h = ch?.handle, !h.isEmpty { Text(h).font(.system(size: 14, weight: .medium)) }
                    if let s = ch?.subscribers, !s.isEmpty {
                        Text("\u{00B7}"); Text(s)
                    }
                }
                .font(.system(size: 14)).foregroundStyle(.secondary)
                Button { applySubscribe() } label: {
                    Text(subscribed ? "Subscribed" : "Subscribe")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(Capsule().fill(subscribed ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(Color.primary)))
                        .foregroundStyle(subscribed ? AnyShapeStyle(Color.primary) : AnyShapeStyle(themeBackground(store.settings.theme)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).clickable()
                .disabled((store.channelInfo?.channelId ?? "").isEmpty)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 16)
        .onAppear { seedSubscribed() }
        .onChange(of: store.channelInfo?.channelId) { _, _ in seedSubscribed() }
    }

    /// Reflect the real subscribed state once the channel loads (once per channel;
    /// never clobbering a tap still in flight — mirrors WatchPage.seedEngagement).
    private func seedSubscribed() {
        guard let ch = store.channelInfo, seededChannel != ch.channelId else { return }
        seededChannel = ch.channelId
        if subWritesInFlight == 0 { subscribed = ch.subscribed ?? false }
    }

    /// Real account write: subscribe / unsubscribe the current channel. Optimistic,
    /// reverts on failure only if we're still on the same channel.
    private func applySubscribe() {
        guard let cid = store.channelInfo?.channelId, !cid.isEmpty else { return }
        let old = subscribed
        let newVal = !subscribed
        subWritesInFlight += 1
        withAnimation(.easeOut(duration: 0.12)) { subscribed = newVal }
        Task {
            let ok = await store.setSubscription(channelId: cid, on: newVal)
            await MainActor.run {
                subWritesInFlight -= 1
                guard !ok, store.channelInfo?.channelId == cid else { return }
                withAnimation(.easeOut(duration: 0.2)) { subscribed = old }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 28) {
            tab("Videos", active: true)
            tab("Playlists", active: false)
            tab("About", active: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private func tab(_ label: String, active: Bool) -> some View {
        VStack(spacing: 8) {
            Text(label).font(.system(size: 15, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
            Rectangle().fill(active ? Color.primary : Color.clear).frame(height: 2)
        }
        .fixedSize()
    }

    @ViewBuilder private var grid: some View {
        if store.channelInfo == nil {
            SkeletonVideoGrid()
        } else if store.videos.isEmpty {
            Text("No videos").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 80)
        } else {
            LazyVGrid(columns: Grid3.videoColumns(for: gridW), spacing: 28) {
                // Channel uploads are unique — stable id identity.
                ForEach(store.videos) { v in
                    Button { store.openWatch(v.id) } label: { VideoCard(video: v) }
                        .buttonStyle(CardPress())
                        .onAppear { if v.id == store.videos.last?.id { Task { await store.loadMore() } } }
                }
            }
            .padding(20)
            if store.loadingMore {
                SkeletonVideoRow()
            }
        }
    }
}

// MARK: - Shorts grid

private struct ShortsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.gridContentWidth) private var gridW

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(Color(red: 1, green: 0, blue: 0.2))
                Text("Shorts").font(.title3.bold())
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider().opacity(0.3)
            ScrollView {
                if let shorts = store.shortsFeed {
                    if shorts.isEmpty {
                        Text("No shorts").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 80)
                    } else {
                        LazyVGrid(columns: Grid3.shortsColumns(for: gridW), spacing: 20) {
                            ForEach(shorts) { s in
                                Button { store.openWatch(s.id) } label: { ShortCard(short: s) }.buttonStyle(.plain)
                            }
                        }
                        .padding(20)
                    }
                } else {
                    SkeletonShortGrid()
                }
            }
        }
        .background(themeBackground(store.settings.theme))
    }
}

private struct ShortCard: View {
    let short: ShortItem
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(
                    CachedImage(url: short.thumbnail) { Rectangle().fill(Color.primary.opacity(0.12)) }
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(hover ? 0.3 : 0), lineWidth: 1))
            Text(shortTitle).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onHover { hover = $0 }
        .clickable()
    }

    // accessibilityText is "Title, N views" — drop the trailing views clause for the card.
    private var shortTitle: String {
        if let r = short.title.range(of: ", ", options: .backwards),
           short.title[r.upperBound...].lowercased().contains("view") {
            return String(short.title[..<r.lowerBound])
        }
        return short.title
    }
}

// MARK: - Notifications

private struct NotificationsPanel: View {
    @EnvironmentObject var store: Store
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications").font(.headline).padding(12)
            Divider()
            if store.notifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("No new notifications").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.notifications) { n in
                            Button {
                                if let vid = n.videoId, !vid.isEmpty { store.openWatch(vid); dismiss() }
                            } label: { NotificationRow(n: n) }
                            .buttonStyle(.plain)
                            .disabled(n.videoId == nil)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 460)
    }
}

private struct NotificationRow: View {
    let n: AppNotification
    @State private var hover = false
    private var isVideo: Bool { (n.videoId ?? "").isEmpty == false }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedImage(url: n.thumbnail) { Rectangle().fill(Color.primary.opacity(0.12)) }
            .frame(width: isVideo ? 68 : 40, height: isVideo ? 38 : 40)
            .clipShape(RoundedRectangle(cornerRadius: isVideo ? 6 : 20))
            VStack(alignment: .leading, spacing: 3) {
                Text(n.text).font(.system(size: 13)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text(n.time).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(hover && isVideo ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .clickable()
    }
}

// MARK: - Playlists grid

private struct PlaylistsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.gridContentWidth) private var gridW

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Playlists").font(.title3.bold()); Spacer() }
                .padding(.horizontal, 20).padding(.vertical, 12)
            Divider().opacity(0.3)
            ScrollView {
                if let pls = store.playlists {
                    if pls.isEmpty {
                        Text("No playlists").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 80)
                    } else {
                        LazyVGrid(columns: Grid3.videoColumns(for: gridW), spacing: 24) {
                            ForEach(pls) { p in
                                Button { store.openPlaylist(p.id, title: p.title, fromGrid: true) } label: {
                                    PlaylistCard(playlist: p)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(20)
                    }
                } else {
                    SkeletonPlaylistGrid()
                }
            }
        }
        .background(themeBackground(store.settings.theme))
    }
}

private struct PlaylistCard: View {
    let playlist: Playlist
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(
                    CachedImage(url: playlist.thumbnail) { Rectangle().fill(Color.primary.opacity(0.12)) }
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up.fill")
                        if !playlist.count.isEmpty { Text(playlist.count) }
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
                }
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(hover ? 0.25 : 0), lineWidth: 1))
            Text(playlist.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onHover { hover = $0 }
        .clickable()
    }
}

// MARK: - Ad card (uBlock native equivalent)

private struct AdCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Ad").font(.caption.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(red: 1, green: 0, blue: 0.2)).foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("Sponsored placement — hidden automatically when Ad Block (uBlock) is on.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(red: 1, green: 0, blue: 0.2), style: StrokeStyle(lineWidth: 1, dash: [5])))
    }
}

// MARK: - Video card

private struct VideoCard: View {
    @EnvironmentObject var store: Store
    let video: VideoListItem
    @State private var hover = false
    @State private var channelHover = false
    // Hover-to-preview state.
    @State private var previewOn = false
    @State private var clip: PreviewClip? = nil
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
            HStack(alignment: .top, spacing: 12) {
                channelAvatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.title(for: video))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    channelLine
                    Text(metaLine).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if hover {
                    Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
        }
        .onHover { hovering in
            hover = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 550_000_000)   // ~0.55s dwell, like YouTube
                    if Task.isCancelled { return }
                    withAnimation(.easeIn(duration: 0.2)) { previewOn = true }
                    // Smooth an_webp where the feed shipped one, else the light sampled-frame cycle.
                    let c = await PreviewCache.load(previewUrl: video.previewUrl, videoId: video.id)
                    if Task.isCancelled { return }
                    withAnimation(.easeIn(duration: 0.2)) { clip = c }
                }
            } else {
                hoverTask = nil
                withAnimation(.easeOut(duration: 0.12)) { previewOn = false }
                clip = nil
            }
        }
        .clickable()
    }

    /// The animated hover preview — always a light CGImage animation: the smooth an_webp clip
    /// where the feed shipped one, else a cross-fading cycle of the video's sampled frames.
    @ViewBuilder private var previewOverlay: some View {
        if previewOn, let clip {
            WebPPreviewView(clip: clip).transition(.opacity)
        }
    }

    private var avatarView: some View {
        AvatarView(url: video.channelAvatar, name: video.channel, size: 36)
    }

    private var channelAvatar: some View {
        Group {
            if let cid = video.channelId, !cid.isEmpty {
                Button { store.openChannel(cid) } label: { avatarView }.buttonStyle(.plain).help("Go to channel")
            } else {
                avatarView
            }
        }
    }

    private var channelLine: some View {
        let label = HStack(spacing: 4) {
            Text(video.channel).font(.system(size: 13)).underline(channelHover)
            Image(systemName: "checkmark.seal.fill").font(.system(size: 10))
        }
        .foregroundStyle(channelHover ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
        return Group {
            if let cid = video.channelId, !cid.isEmpty {
                Button { store.openChannel(cid) } label: { label }
                    .buttonStyle(.plain)
                    .onHover { channelHover = $0 }
                    .help("Go to channel")
            } else {
                label
            }
        }
    }

    private var thumbnail: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)   // full-width, scales with the column
            .frame(maxWidth: .infinity)
            .overlay(
                CachedImage(url: store.thumbnail(for: video)) { Rectangle().fill(Color.primary.opacity(0.12)) }
            )
            .overlay { previewOverlay.allowsHitTesting(false) }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            if store.hasSponsor(video) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(5)
                    .background(Color.green.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .help("SponsorBlock: this video has community skip segments")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if store.isDeArrowed(video) {
                Text("DeArrow").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color(red: 0, green: 0.7, blue: 0.85)).foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let d = store.durationLabel(for: video) {
                Text(d).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.8)).foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(hover ? 0.25 : 0), lineWidth: 1))
    }

    private var metaLine: String {
        let parts = [video.viewCountText, video.publishedText].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? pseudoMeta(video.id) : parts.joined(separator: " · ")
    }

    private func pseudoMeta(_ id: String) -> String {
        let h = abs(id.hashValue)
        let views = ["1.2M", "834K", "2.1M", "456K", "3.4M", "998K", "671K", "1.8M"][h % 8]
        let times = ["3 days ago", "1 week ago", "2 days ago", "5 hours ago", "1 month ago", "yesterday"][h % 6]
        return "\(views) views · \(times)"
    }
}

// MARK: - Logo

struct CommentRow: View {
    let comment: Comment
    @State private var likeState = 0        // -1 dislike, 0 none, 1 like (visual only)
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(url: comment.avatar, name: comment.author, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.author).font(.system(size: 13, weight: .semibold))
                    Text(comment.published).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(comment.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button { withAnimation(.easeOut(duration: 0.1)) { likeState = likeState == 1 ? 0 : 1 } } label: {
                        Label(comment.likes.isEmpty ? "0" : comment.likes,
                              systemImage: likeState == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .foregroundStyle(likeState == 1 ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                    }.buttonStyle(.plain).clickable()
                    Button { withAnimation(.easeOut(duration: 0.1)) { likeState = likeState == -1 ? 0 : -1 } } label: {
                        Image(systemName: likeState == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .foregroundStyle(likeState == -1 ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                    }.buttonStyle(.plain).clickable()
                    if !comment.replies.isEmpty {
                        Text("\(comment.replies) replies").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
            }
            Spacer(minLength: 0)
        }
    }
}

struct LogoMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(red: 1, green: 0, blue: 0.2)).frame(width: 30, height: 21)
            Image(systemName: "play.fill").foregroundColor(.white).font(.system(size: 10))
        }
    }
}

/// The SmartTube wordmark (play button + white "SmartTube"), bundled at
/// Resources/smarttube-logo.png by package.sh. It's a horizontal lockup that already includes
/// the name, so it stands in for the old LogoMark + "YouTube" text together. Loaded once and
/// cached; falls back to the drawn LogoMark if the asset is missing (e.g. a bare `swift run`).
struct BrandLogo: View {
    var height: CGFloat = 26
    private static let image: NSImage? = Bundle.main.url(forResource: "smarttube-logo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        if let img = BrandLogo.image {
            Image(nsImage: img).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit).frame(height: height)
                .accessibilityLabel("SmartTube")
        } else {
            LogoMark()   // fallback for dev/unbundled runs
        }
    }
}
