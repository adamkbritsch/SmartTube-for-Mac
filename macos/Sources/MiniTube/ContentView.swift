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
    // OLED dark: pure #000 so black pixels are truly off on OLED panels. Elevated
    // surfaces use Color.primary.opacity(...) which reads as subtle near-black on top.
    theme == "dark" ? Color.black : Color(red: 0.97, green: 0.97, blue: 0.97)
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
    /// Result of an action fired from a card's 3-dot menu — a Visionary send, "Mark as watched".
    ///
    /// This used to live inside FeedView, so it could only ever be seen on the feed. Firing the same
    /// menu row from a channel page, a playlist, or the watch page's up-next rail did the work and
    /// showed NOTHING, which read as the row being dead. It belongs at the root because the menu
    /// does.
    @ViewBuilder private var actionNoteLayer: some View {
        if let note = store.actionNote {
            VStack {
                Spacer()
                Label(note, systemImage: store.actionNoteIsError ? "exclamationmark.triangle.fill" : "checkmark")
                    .font(.system(size: 13))
                    .foregroundStyle(store.actionNoteIsError ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.primary))
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.12)))
                    .background(RoundedRectangle(cornerRadius: 10).fill(themeBackground(store.settings.theme)))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .allowsHitTesting(false)   // a transient status must never swallow a click
        }
    }

    @State private var selectedSidebar = "Home"
    @State private var sidebarCollapsed = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            actionNoteLayer.zIndex(9)   // above every page; see the property below
            VStack(spacing: 0) {
                HeaderBar(search: $search, sidebarCollapsed: $sidebarCollapsed, showSettings: $showSettings)
                    .zIndex(2)   // the search dropdown hangs below the header, over the content
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
            .sheet(isPresented: $showSettings) {
                SettingsSheet().environmentObject(store)
            }
        }
        .preferredColorScheme(store.settings.theme == "dark" ? .dark : .light)
        .frame(minWidth: 940, minHeight: 580)
        .onAppear {
            // Keyboard navigation: what Enter and Escape do at the top level. Kept here (rather
            // than as per-row closures) so nothing long-lived captures a transient SwiftUI view.
            let engine = FocusEngine.shared
            engine.activate = { target in
                switch target.zone {
                case .grid:
                    if let id = engine.id(target) { store.openItemById(id) }
                default: break
                }
            }
            engine.escape = {
                if store.watchVideoId != nil || store.canGoBack { store.goBack() }
            }
            engine.suspended = store.watchVideoId != nil
        }
        // On the watch page the arrows belong to the player (YouTube's own ←/→ seek), so the
        // engine stands down rather than moving focus around the feed hidden behind the overlay.
        .onChange(of: store.watchVideoId) { _, id in
            FocusEngine.shared.suspended = id != nil
        }
        .onAppear {
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
            // Whether the sharpen is ACTUALLY applied right now. The player reports this every
            // second and nothing displayed it — Settings only shows which preset is chosen, so a
            // user who picked "Sharper" had no way to see that it had auto-disabled (it turns
            // itself off at 4K, and while GPU saver is on because Visionary is rendering).
            if playback.enhanceActive {
                Text("ENHANCED").font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Capsule().fill(Color.primary.opacity(0.12)))
                    .foregroundStyle(.secondary)
                    .help("GPU detail-sharpen is being applied to this video")
            }
        }
    }

    // Decoded height only; the Enhance chip above reports whether the sharpen is live.
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
    /// Autoplay preference. Was per-WatchPage @State defaulting to true, so it silently reset to ON
    /// for every video — switching it off only lasted until the next one.
    @AppStorage("autoplayNext") private var autoplay = true
    @State private var descExpanded = false
    // Mini-player state: the reserved slot's live frame, plus the user's dragged offset.
    @State private var slotFrame: CGRect = .zero
    @State private var miniDrag: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    // Engagement state (backed by real account writes via the backend).
    @State private var subscribed = false
    @State private var likeState = 0          // -1 dislike, 0 none, 1 like
    @State private var shareCopied = false
    @State private var seededVideoId = ""     // metadata state applied once per video
    @State private var likeWritesInFlight = 0
    @State private var seededLikeState = 0     // like state the server's count already reflects
    // "Send to Visionary" (4K Dolby Vision upscale) — button only exists while its engine answers.
    @ObservedObject private var visionary = VisionaryBridge.shared
    @State private var visionarySending = false
    @State private var visionaryResult: VisionaryBridge.SendResult?
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
                  sbCategories: store.settings.sbCategories,
                  adPruneKeys: store.adRules.pruneKeys, adScrubKeys: store.adRules.scrubKeys,
                  onEnhanceInfo: { h, a, hdr in Task { @MainActor in store.reportEnhance(height: h, amount: a, hdr: hdr) } },
                  onEnded: {
                      // Reads LIVE store state rather than `filteredRecs`, which goes through the
                      // view's captured `videoId`. Belt-and-braces with the coordinator refresh in
                      // WebPlayer.updateNSView: autoplay must not depend on when this closure was
                      // captured.
                      Task { @MainActor in
                          guard autoplay,
                                let next = store.watchInfo?.recommendations.first else { return }
                          store.openWatch(next.id)
                      }
                  },
                  onTheater: {
                      // YouTube's in-player theater button → the app's theater (widen).
                      Task { @MainActor in store.setTheater(!store.settings.theaterMode) }
                  },
                  onMarkWatched: { vid in
                      // Watched past the threshold → log the view to YouTube history.
                      Task { @MainActor in await store.markWatched(vid) }
                  })
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        // The player FLOATS above the scroll content instead of living inside it. It is one single
        // view instance whose frame is animated between "docked over its placeholder" and "mini in
        // the corner" — it is never moved between two branches of the view tree, because that would
        // make SwiftUI tear down and rebuild the WKWebView and RELOAD the video mid-playback.
        GeometryReader { outer in
            ZStack(alignment: .topLeading) {
                scrollBody(outer.size)
                floatingPlayer(in: outer.size, origin: outer.frame(in: .global).origin)
            }
            .clipped()
            .overlay(alignment: .bottom) {
                if let err = store.feedbackError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.12)))
                        .background(RoundedRectangle(cornerRadius: 10).fill(themeBackground(store.settings.theme)))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: videoId) { _, _ in miniDrag = .zero; dragStart = .zero }
        }
    }

    private static let minScale: CGFloat = 1.0 / 3.0    // shrinks to a third, then stays
    private static let pinY: CGFloat = 12               // where it parks while shrunk

    /// The player's full (docked) width for a given container — also used for the placeholder's
    /// height, because a flexible `Color.clear` + aspectRatio collapses to zero inside a ScrollView.
    private func fullPlayerWidth(_ container: CGSize) -> CGFloat {
        let railW: CGFloat = store.settings.theaterMode ? 0 : 426   // rail 402 + 24 spacing
        return max(240, container.width - railW - 40)               // minus the column's 20pt padding
    }

    /// How far the player has shrunk: 0 = fully docked, 1 = parked at `minScale`. Driven directly by
    /// scroll position, so the video scales smoothly as you scroll rather than snapping.
    private func shrinkProgress(_ container: CGSize, localSlotY: CGFloat) -> CGFloat {
        guard slotFrame.width > 1 else { return 0 }
        let fullH = fullPlayerWidth(container) * 9 / 16
        let travel = max(1, fullH * 0.8)                 // fully shrunk after ~80% of it scrolls by
        let past = max(0, Self.pinY - localSlotY)        // how far the slot went above the pin line
        return min(1, past / travel)
    }

    @ViewBuilder private func floatingPlayer(in container: CGSize, origin: CGPoint) -> some View {
        // Slot position relative to this container (both measured globally).
        let localSlotX = slotFrame.minX - origin.x
        let localSlotY = slotFrame.minY - origin.y
        let t = shrinkProgress(container, localSlotY: localSlotY)
        let shrunk = t > 0.01
        let fullW = slotFrame.width > 1 ? slotFrame.width : fullPlayerWidth(container)
        let scale = 1 - t * (1 - Self.minScale)
        let w = fullW * scale
        let h = w * 9 / 16
        // Docked it tracks the slot exactly; once it reaches the pin line it stays there and
        // shrinks in place, plus wherever the user has dragged it.
        let baseX = slotFrame.width > 1 ? localSlotX : 20
        let baseY = max(Self.pinY, slotFrame.width > 1 ? localSlotY : 20)
        let x = min(max(baseX + (shrunk ? miniDrag.width : 0), 8), max(8, container.width - w - 8))
        let y = min(max(baseY + (shrunk ? miniDrag.height : 0), 8), max(8, container.height - h - 8))

        playerSlot
            .frame(width: max(1, w), height: max(1, h))
            // Shadow goes on a BACKGROUND shape, never on the player itself: a .shadow() wrapping
            // the WKWebView forces it into an offscreen-rendered layer, which is the same class of
            // layer-compositing trap that once made 4K video decode but paint solid black.
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.5 * t), radius: 18 * t, y: 8 * t)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.14 * t), lineWidth: 1)
            )
            .offset(x: x, y: y)
            // `including:` is load-bearing, not a tidy-up. The guard inside onChanged stops the
            // STATE update, but the recognizer was still installed over the web view at full size,
            // and a DragGesture with a minimumDistance holds mouse-down while it waits to see
            // whether the movement becomes a drag — so YouTube's own controls never saw the click.
            // That is why the on-screen fullscreen button did nothing (auto-fullscreen still
            // worked, because it clicks the button from the host side, bypassing AppKit entirely).
            // `.subviews` leaves the gesture inert at full size and lets the clicks through.
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        guard shrunk else { return }   // draggable only once it's shrunk
                        miniDrag = CGSize(width: dragStart.width + g.translation.width,
                                          height: dragStart.height + g.translation.height)
                    }
                    .onEnded { _ in if shrunk { dragStart = miniDrag } },
                including: shrunk ? .all : .subviews
            )
    }

    // ONE scroll view over BOTH columns so the up-next rail scrolls together with the
    // player/description/comments (was two independent ScrollViews). A vertical ScrollView
    // fixes the cross-axis width, so the main column takes the remaining space and the rail
    // stays a fixed 402pt beside it.
    private func scrollBody(_ container: CGSize) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    // Reserves the player's space in the layout and reports where it is; the real
                    // player is drawn over it by floatingPlayer. The height is set EXPLICITLY —
                    // a flexible Color.clear with .aspectRatio collapses to 0x0 inside a ScrollView
                    // (unbounded height proposal), which silently disabled the whole mini player.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: (fullPlayerWidth(container) * 9 / 16).rounded())
                        // Report the slot's live position straight into state. (A PreferenceKey was
                        // tried first and never propagated out of the ScrollView — the reader was
                        // laid out correctly but the ancestor only ever saw the default value.)
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { slotFrame = g.frame(in: .global) }
                                .onChange(of: g.frame(in: .global)) { _, f in
                                    // Fires on every scroll frame — ignore sub-pixel noise so we
                                    // don't re-render the watch page more often than we must.
                                    if abs(f.minY - slotFrame.minY) >= 0.5
                                        || abs(f.width - slotFrame.width) >= 0.5 { slotFrame = f }
                                }
                        })
                    playerBar

                    Text(info?.title ?? "Loading…")
                        .font(.title2.bold()).lineLimit(3).textSelection(.enabled)

                    channelRow
                    descriptionBox
                    commentsSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)

                if !store.settings.theaterMode {
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
                    .frame(width: 402)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.settings.theaterMode)
        .onChange(of: videoId) { _, _ in
            subscribed = false; likeState = 0; shareCopied = false; selectedChip = "All"; descExpanded = false
            visionaryResult = nil; visionarySending = false
            visionary.refreshAvailability()   // cached ~60s; never blocks
        }
        .onAppear {
            seedEngagement(); visionary.refreshAvailability()
            // Plex `info` (I) toggles the description while the watch page is up.
            FocusEngine.shared.showInfo = { withAnimation(.easeInOut(duration: 0.15)) { descExpanded.toggle() } }
        }
        .onDisappear { FocusEngine.shared.showInfo = nil }
        .onChange(of: store.watchInfo?.videoId) { _, _ in seedEngagement() }
    }


    /// Reflect the real subscribed / like state once this video's metadata arrives.
    /// Seeds at most once per video, and never over a user tap that's still in
    /// flight — the server snapshot predates the tap and would undo it.
    private func seedEngagement() {
        guard let i = info, seededVideoId != videoId else { return }
        seededVideoId = videoId
        if subscribeWritesInFlight == 0 { subscribed = i.subscribed ?? false }
        if likeWritesInFlight == 0 {
            MTDebug.log("[like] seed from server likeStatus=\(String(describing: i.likeStatus)) (was \(likeState))")
            likeState = i.likeStatus ?? 0
            seededLikeState = likeState   // the count already includes a like the server knew about
        }
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
        // LazyVStack (NOT VStack): comments materialize as they scroll into view. A plain VStack
        // laid out EVERY comment immediately, so the last row's `.onAppear` fired at once →
        // loadMoreComments → append → new last row's `.onAppear` fires immediately → … a runaway
        // pagination + full-list re-layout loop that pinned the main thread at ~100% (profiled).
        // Lazily, `.onAppear` fires only when a row actually scrolls in, so pagination is correct.
        LazyVStack(alignment: .leading, spacing: 16) {
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
                    // The uploader's REAL avatar — this was hardcoded to nil, so every channel on
                    // the watch page fell back to a monogram even though YouTube ships the picture.
                    AvatarView(url: info?.channelAvatar, name: info?.channel ?? "?", size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(info?.channel ?? " ").font(.system(size: 15, weight: .semibold))
                            if info?.channelVerified == true {
                                Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
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
            // The ACTIVE side gets a filled accent pill, not just a tinted glyph. Previously the
            // only feedback was a subtle icon fill — and because YouTube's count reads the same
            // either way ("15K" +1 is still "15K"), a successful like looked like nothing had
            // happened, so it was easy to click again and silently undo it.
            HStack(spacing: 0) {
                Button { applyLike(1) } label: {
                    Label(likeCountText, systemImage: likeState == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 13, weight: likeState == 1 ? .semibold : .medium))
                        .padding(.horizontal, 14).frame(height: 36)
                        .foregroundStyle(likeState == 1 ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                        .background(Capsule().fill(likeState == 1 ? AnyShapeStyle(accent) : AnyShapeStyle(Color.clear)))
                }.buttonStyle(.plain).clickable()
                .help(likeState == 1 ? "You liked this — click again to remove" : "Like")
                Divider().frame(height: 18).opacity(0.4)
                Button { applyLike(-1) } label: {
                    Image(systemName: likeState == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 36)
                        .foregroundStyle(likeState == -1 ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                        .background(Capsule().fill(likeState == -1 ? AnyShapeStyle(accent) : AnyShapeStyle(Color.clear)))
                }.buttonStyle(.plain).clickable()
                .help(likeState == -1 ? "You disliked this — click again to remove" : "Dislike")
            }
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .animation(.easeOut(duration: 0.15), value: likeState)
            Button { copyShareURL() } label: {
                Label(shareCopied ? "Copied!" : "Share",
                      systemImage: shareCopied ? "checkmark" : "arrowshape.turn.up.right")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }.buttonStyle(.plain).clickable()

            // Only shown while Visionary's local engine actually answers — no disabled ghost when
            // the app isn't running.
            if visionary.canSend("video") {
                Button { sendToVisionary() } label: {
                    Label(visionarySendLabel, systemImage: visionarySendSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 36)
                        .foregroundStyle(visionaryResult?.isError == true ? AnyShapeStyle(Color.orange)
                                                                          : AnyShapeStyle(Color.primary))
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain).clickable()
                .disabled(visionarySending)
                .help("Upscale this video to 4K Dolby Vision with Visionary")
                .animation(.easeOut(duration: 0.15), value: visionaryResult)
            }
        }
    }

    private var visionarySendLabel: String {
        if visionarySending { return "Sending…" }
        return visionaryResult?.label ?? "Send to Visionary"
    }
    private var visionarySendSymbol: String {
        if visionarySending { return "arrow.up.square" }
        return visionaryResult?.symbol ?? "arrow.up.square"
    }

    /// Hand this video to Visionary's upscale pipeline. Fire-and-forget: Visionary fetches it via
    /// its downloader and upscales it next in its queue, which takes a long time — so this reports
    /// a one-shot result on the button and never tries to track progress.
    private func sendToVisionary() {
        guard !visionarySending else { return }
        visionarySending = true
        visionaryResult = nil
        let id = videoId
        let name = info?.title ?? store.watchInfo?.title ?? ""
        Task {
            let result = await visionary.send(videoId: id, title: name)
            await MainActor.run {
                visionarySending = false
                guard store.watchVideoId == id else { return }   // user navigated away
                visionaryResult = result
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { visionaryResult = nil }
            }
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
    /// The like count with the user's own like folded in, so the number moves the moment they
    /// tap. YouTube's formatted count ("15K") wouldn't visibly change on ±1, so an exact count
    /// is adjusted and a rounded one is left alone (bumping "15K" to "15K" would be noise).
    private var likeCountText: String {
        let base = info?.likes ?? ""
        guard likeState == 1, seededLikeState != 1 else { return base }
        let digits = base.filter { $0.isNumber }
        guard !base.isEmpty, base.allSatisfy({ $0.isNumber || $0 == "," }), let n = Int(digits) else { return base }
        return (n + 1).formatted(.number)
    }

    private func applyLike(_ target: Int) {
        let old = likeState
        let newState = likeState == target ? 0 : target
        let forVideo = videoId
        likeWritesInFlight += 1
        withAnimation(.easeOut(duration: 0.12)) { likeState = newState }
        let action = newState == 1 ? "like" : (newState == -1 ? "dislike" : "none")
        MTDebug.log("[like] tap target=\(target) old=\(old) new=\(newState) action=\(action) video=\(forVideo)")
        Task {
            let ok = await store.setLike(videoId: forVideo, state: action)
            await MainActor.run {
                likeWritesInFlight -= 1
                MTDebug.log("[like] result ok=\(ok) stateNow=\(likeState) sameVideo=\(store.watchVideoId == forVideo)")
                guard !ok, store.watchVideoId == forVideo else { return }
                MTDebug.log("[like] REVERTING to \(old)")
                // Say so — a silent snap-back is indistinguishable from "the click didn't land".
                store.feedbackError = target == 1 ? "Couldn't like this video" : "Couldn't dislike this video"
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    withAnimation { store.feedbackError = nil }
                }
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
    /// Deduped, capped set of links worth previewing (a description often repeats the same
    /// sponsor URL several times).
    private func uniqueLinks(_ links: [DescriptionLink]) -> [DescriptionLink] {
        var seen = Set<String>()
        return links.filter { seen.insert($0.url).inserted }.prefix(6).map { $0 }
    }

    /// Description text with real, clickable links. YouTube truncates/shortens the DISPLAY text
    /// (`https://linustechtips.com/t…`) and keeps the true destination in the run's endpoint, so we
    /// apply `.link` at the ranges the backend extracted (UTF-16 offsets, bounds-checked) rather
    /// than regexing the visible text. Anything the runs didn't cover — bare URLs in descriptions
    /// that predate attributedDescription — is caught by NSDataDetector.
    static func attributedDescription(_ text: String, links: [DescriptionLink]) -> AttributedString {
        var out = AttributedString(text)
        let utf16Count = text.utf16.count
        var covered: [Range<Int>] = []

        for l in links {
            guard l.start >= 0, l.length > 0, l.start + l.length <= utf16Count,
                  let url = URL(string: l.url) else { continue }
            guard let lo = String.Index(String.UTF16View.Index(utf16Offset: l.start, in: text), within: text),
                  let hi = String.Index(String.UTF16View.Index(utf16Offset: l.start + l.length, in: text), within: text),
                  let range = Range(lo..<hi, in: out) else { continue }
            out[range].link = url
            out[range].underlineStyle = .single
            covered.append(l.start..<(l.start + l.length))
        }

        // Fallback for bare URLs no run covered.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = text as NSString
            for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url, url.scheme == "http" || url.scheme == "https" else { continue }
                let r = m.range.location..<(m.range.location + m.range.length)
                if covered.contains(where: { $0.overlaps(r) }) { continue }
                guard let lo = String.Index(String.UTF16View.Index(utf16Offset: r.lowerBound, in: text), within: text),
                      let hi = String.Index(String.UTF16View.Index(utf16Offset: r.upperBound, in: text), within: text),
                      let range = Range(lo..<hi, in: out) else { continue }
                out[range].link = url
                out[range].underlineStyle = .single
            }
        }
        return out
    }

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
                    Text(Self.attributedDescription(desc, links: info?.descriptionLinks ?? []))
                        .font(.system(size: 13)).textSelection(.enabled)
                        .tint(Color(red: 0.24, green: 0.65, blue: 1))
                        .lineLimit(descExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                    // Only offer the toggle when there's actually more to show (a 1-2 line
                    // description used to display a "…more" that visibly did nothing).
                    if descExpanded || desc.count > 140 || desc.contains("\n") {
                        Button(descExpanded ? "Show less" : "…more") {
                            withAnimation(.easeInOut(duration: 0.15)) { descExpanded.toggle() }
                        }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).clickable()
                    }
                    // Gmail-style link cards — ONLY once expanded, so nothing is fetched (and no
                    // third-party site learns you opened the video) for descriptions you never read.
                    if descExpanded {
                        let links = uniqueLinks(info?.descriptionLinks ?? [])
                        if !links.isEmpty {
                            Divider().opacity(0.15).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(links, id: \.url) { l in
                                    LinkPreviewCard(link: l, preview: store.linkPreviews[l.url])
                                        .onTapGesture { store.openURL(l.url) }
                                }
                            }
                            .task(id: videoId) { await store.loadLinkPreviews(links) }
                        }
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// A Gmail-style preview card for one description link. Shown only under an EXPANDED description.
/// Degrades honestly: until (or unless) metadata arrives it still shows the real destination host,
/// so the card always answers "where does this go?" even for sites that block preview fetches.
private struct LinkPreviewCard: View {
    let link: DescriptionLink
    let preview: LinkPreview?
    @State private var hover = false

    private var host: String {
        preview?.host ?? URL(string: link.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? link.url
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let img = preview?.image, !img.isEmpty {
                CachedImage(url: img) { Rectangle().fill(Color.primary.opacity(0.12)) }
                    .frame(width: 96, height: 54).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.10))
                    .frame(width: 96, height: 54)
                    .overlay(Image(systemName: "link").font(.system(size: 16)).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preview?.title ?? link.url)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .foregroundStyle(.primary)
                if let d = preview?.description, !d.isEmpty {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(preview?.siteName.map { "\($0) · \(host)" } ?? host)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hover ? 0.10 : 0.05)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .clickable()
        .help(link.url)
    }
}

struct RecRow: View {
    @EnvironmentObject var store: Store
    let video: VideoListItem
    @State private var hover = false
    @State private var showMenu = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                // store.thumbnail/title, not the raw originals: the up-next rail used to ignore the
                // DeArrow setting every other card honours, so flipping it changed the feed and the
                // watch page but silently not this rail.
                CachedImage(url: store.thumbnail(for: video)) { Rectangle().fill(Color.primary.opacity(0.12)) }
                .frame(width: 168, height: 94).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                if let d = store.durationLabel(for: video) {
                    Text(d).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.black.opacity(0.8)).foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4)).padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(store.title(for: video)).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(video.channel).font(.system(size: 12)).foregroundStyle(.secondary)
                Text([video.viewCountText, video.publishedText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // The rail had no overflow menu at all, so its cards couldn't be sent to Visionary,
            // copied, or marked watched — and YouTube's own feedback actions for these items were
            // received and dropped.
            if hover || showMenu {
                Button { showMenu.toggle() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(showMenu ? 0.12 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).clickable()
                .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                    VideoCardMenu(video: video, dismiss: { showMenu = false })
                        .environmentObject(store)
                }
            }
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
        VStack(spacing: 16) {
            HStack(spacing: 8) { LogoMark(); Text("Sign in to YouTube").font(.title3.bold()) }

            switch status {
            case "webLogin":
                // The real Google login, hosted in the app's own session store.
                SignInWebView(onSuccess: { store.signInSucceeded() },
                              onBlocked: { store.signInBlocked() })
                    .frame(width: 460, height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Use my Firefox login instead") { store.signInViaFirefox() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            case "webBlocked":
                message("lock.trianglebadge.exclamationmark",
                        "Google blocked the in-app login",
                        "Google sometimes refuses sign-in inside an embedded browser. You can attach using your existing YouTube login in Firefox instead.")
                HStack(spacing: 10) {
                    Button("Try again") { store.signIn() }
                    Button("Use my Firefox login") { store.signInViaFirefox() }.buttonStyle(.borderedProminent)
                }
            case "connecting":
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Finishing sign-in…").foregroundStyle(.secondary)
                }
            case "success":
                message("checkmark.circle.fill", "Signed in", "")
            case "no_session":
                message("person.crop.circle.badge.exclamationmark",
                        "No YouTube login found",
                        "Sign in with Google above, or make sure you're logged into youtube.com in Firefox and try again.")
                HStack(spacing: 10) {
                    Button("Sign in with Google") { store.signIn() }
                    Button("Try Firefox again") { store.signInViaFirefox() }.buttonStyle(.borderedProminent)
                }
            default: // error
                message("xmark.circle.fill", "Couldn't complete sign-in",
                        "The login didn't establish a working YouTube session. Try again, or use your Firefox login.")
                HStack(spacing: 10) {
                    Button("Try again") { store.signIn() }
                    Button("Use Firefox login") { store.signInViaFirefox() }.buttonStyle(.borderedProminent)
                }
            }

            Button("Cancel") { store.cancelSignIn() }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(status == "webLogin" ? 16 : 32)
        .frame(width: status == "webLogin" ? 500 : 430)
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
    @Binding var showSettings: Bool
    @State private var showNotifications = false
    @State private var showAccountMenu = false
    @FocusState private var searchFocused: Bool
    @State private var suggestions: [String] = []          // YouTube's predictions for the typed text
    @State private var suggestTask: Task<Void, Never>?
    @State private var highlighted: Int?                   // arrow-key selection in the dropdown

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
            // A Button + popover, NOT a Menu: macOS renders Menu labels through AppKit menu
            // chrome, which mangles a resizable/async Image into a broken-image glyph. Plain
            // Buttons render the avatar correctly (same as the sidebar avatars).
            Button { showAccountMenu.toggle() } label: {
                avatarImage(p.picture)
            }
            .buttonStyle(.plain).clickable().help(p.name)
            .popover(isPresented: $showAccountMenu, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        avatarImage(p.picture)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: 14, weight: .semibold))
                            if !p.email.isEmpty { Text(p.email).font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                    Divider()
                    Button { showAccountMenu = false; store.signOut() } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).clickable()
                }
                .frame(width: 250)
            }
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
            searchTextField
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
        // Report where the capsule is so an outside click can dismiss it (see FocusEngine).
        .background(GeometryReader { g in
            Color.clear
                .onAppear { FocusEngine.shared.searchFieldRect = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, r in FocusEngine.shared.searchFieldRect = r }
        })
        // The suggestions dropdown hangs below the capsule. It renders past the header's bounds, so
        // HeaderBar carries a zIndex in the root VStack — later siblings would otherwise draw AND
        // hit-test over it.
        .overlay(alignment: .topLeading) {
            if searchFocused, !suggestionRows.isEmpty {
                suggestionsDropdown
                    .offset(y: 44)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { FocusEngine.shared.suggestionsRect = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, r in FocusEngine.shared.suggestionsRect = r }
                            .onDisappear { FocusEngine.shared.suggestionsRect = .zero }
                    })
            }
        }
    }

    /// Split from searchField: the combined modifier chain blew the type-checker's budget.
    private var searchTextField: some View {
        TextField("Search", text: $search)
                .onChange(of: store.focusSearchTick) { _, _ in searchFocused = true }
                .onChange(of: searchFocused) { _, on in
                    // Hand the Plex key map the one fact it can't infer: the keyboard is being used
                    // to TYPE, not to drive the UI.
                    FocusEngine.shared.textEntry = on
                    FocusEngine.shared.blurText = { searchFocused = false }
                    if !on {
                        suggestions = []; highlighted = nil
                        FocusEngine.shared.suggestionsRect = .zero
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit {
                    if let h = highlighted, suggestionRows.indices.contains(h) { pick(suggestionRows[h].text) }
                    else { pick(search) }
                }
                // Arrow keys select in the dropdown while it's open (onKeyPress runs on the FOCUSED
                // view, so this works exactly while typing — the app-level monitor passes keys
                // through during text entry). .handled stops the caret from moving.
                .onKeyPress(.downArrow) {
                    guard searchFocused, !suggestionRows.isEmpty else { return .ignored }
                    highlighted = ((highlighted ?? -1) + 1) % suggestionRows.count
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard searchFocused, !suggestionRows.isEmpty else { return .ignored }
                    highlighted = ((highlighted ?? suggestionRows.count) - 1 + suggestionRows.count) % suggestionRows.count
                    return .handled
                }
                .onChange(of: search) { _, q in
                    highlighted = nil
                    suggestTask?.cancel()
                    let t = q.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { suggestions = []; return }
                    // Debounce so a fast typist fires one request, not one per keystroke.
                    suggestTask = Task {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        guard !Task.isCancelled else { return }
                        let list = await store.fetchSuggestions(t)
                        if !Task.isCancelled, search.trimmingCharacters(in: .whitespaces) == t {
                            suggestions = list
                        }
                    }
                }
    }

    /// What the dropdown shows. Empty field → recent searches. Typing → recents that match the
    /// prefix first (clock icon, like YouTube), then YouTube's own predictions, deduplicated.
    private var suggestionRows: [(text: String, recent: Bool)] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return store.recentSearches.prefix(8).map { ($0, true) } }
        let rec = store.recentSearches
            .filter { $0.lowercased().hasPrefix(q.lowercased()) }
            .prefix(3).map { ($0, true) }
        let seen = Set(rec.map { $0.0.lowercased() })
        let yt = suggestions
            .filter { !seen.contains($0.lowercased()) }
            .prefix(10 - rec.count).map { ($0, false) }
        return Array(rec) + Array(yt)
    }

    private func pick(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        suggestTask?.cancel()
        search = t
        suggestions = []; highlighted = nil
        searchFocused = false
        store.search(t)
    }

    private var suggestionsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestionRows.enumerated()), id: \.offset) { idx, row in
                SuggestionRow(text: row.text, recent: row.recent,
                              highlighted: highlighted == idx,
                              pick: { pick(row.text) },
                              remove: row.recent ? { store.removeRecentSearch(row.text) } : nil)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        .background(RoundedRectangle(cornerRadius: 12).fill(themeBackground(store.settings.theme)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

}

/// One dropdown row: clock = a saved recent search (removable), magnifier = YouTube's prediction.
private struct SuggestionRow: View {
    let text: String
    let recent: Bool
    let highlighted: Bool
    let pick: () -> Void
    var remove: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recent ? "clock" : "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            if recent, hover, let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).clickable().help("Remove from history")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(highlighted || hover ? 0.10 : 0)))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .onHover { hover = $0 }
        .clickable()
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var selected: String
    var collapsed: Bool = false
    @State private var subsExpanded = false
    @State private var youExpanded = true
    private let subsCollapsedLimit = 7

    var body: some View {
        (collapsed ? AnyView(miniRail) : AnyView(fullSidebar))
            // Publish the focusable rows so the engine can navigate into and through the sidebar.
            // Without this, Left from the feed's first column had nowhere to go and did nothing.
            .onAppear { FocusEngine.shared.setItems(.sidebar, focusItems) }
            .onChange(of: focusItems) { _, items in FocusEngine.shared.setItems(.sidebar, items) }
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
        // One behaviour for both sidebars: this used to duplicate the switch and silently omit
        // "You", so the fourth rail tile hovered and pressed like the others and did nothing.
        Button { activateRow(label) } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(label).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 10).fill(store.currentSection == label ? Color.primary.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
        .modifier(OptionalFocus(target: focusTarget(label), shape: .rect(10)) { activateRow(label) })
        .padding(.horizontal, 6)
    }

    private var fullSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row("Home", "house.fill")
                row("Shorts", "play.rectangle.fill")
                row("Subscriptions", "play.square.stack.fill")

                // Signed in this really is the subscription list; signed out it's just the
                // distinct channels in the current feed, so it must not claim to be subscriptions.
                sectionHeader(store.account.signedIn && !store.account.subscriptions.isEmpty
                              ? "Subscriptions" : "Channels in your feed", trailing: nil)
                if store.account.signedIn && !store.account.subscriptions.isEmpty {
                    let subs = store.account.subscriptions
                    let shown = subsExpanded ? subs : Array(subs.prefix(subsCollapsedLimit))
                    ForEach(shown) { channelRow(title: $0.title, thumb: $0.thumbnail, channelId: $0.channelId) }
                    if subs.count > subsCollapsedLimit { showMoreRow }
                } else {
                    let subs = store.subscriptions
                    let shown = subsExpanded ? subs : Array(subs.prefix(subsCollapsedLimit))
                    // channelId resolved from the feed: these rows were dead buttons without it.
                    ForEach(shown, id: \.self) { channelRow(title: $0, thumb: nil, channelId: store.channelId(forName: $0)) }
                    if subs.count > subsCollapsedLimit { showMoreRow }
                }

                // The chevron used to be pure decoration. It now does what a disclosure chevron
                // says it does: collapse and expand the "You" rows beneath it.
                sectionHeader("You", trailing: youExpanded ? "chevron.down" : "chevron.right") {
                    withAnimation(.easeInOut(duration: 0.18)) { youExpanded.toggle() }
                }
                if youExpanded {
                    row("Your channel", "person.crop.square")
                    row("History", "clock.arrow.circlepath")
                    row("Playlists", "list.bullet.rectangle")
                    row("Watch later", "clock")
                    row("Liked videos", "hand.thumbsup")
                    row("Your videos", "play.square")
                }
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
        .modifier(OptionalFocus(target: focusTarget("__more"), shape: .rect(10)) { withAnimation(.easeInOut(duration: 0.18)) { subsExpanded.toggle() } })
    }

    /// One implementation of a sidebar row's behaviour, shared by the click and by Enter.
    private func activateRow(_ label: String) {
        selected = label
        switch label {
        case "Home": store.goHome()
        case "Shorts": store.openShorts()
        case "Subscriptions": store.openSubscriptions()
        case "History": store.openHistory()
        case "Playlists": store.openPlaylists()
        case "Watch later": store.openWatchLater()
        case "Liked videos": store.openLiked()
        case "Your channel", "You": store.openMyChannel()
        // "Your videos" used to be an alias for "Your channel" — same page, two labels. It now
        // opens the channel and selects its Videos tab.
        case "Your videos": store.openMyChannel(tabSlug: "videos")
        default: break
        }
    }

    /// The sidebar rows that can hold keyboard focus, in visual order. Section headers are skipped
    /// (they aren't interactive), and the list tracks the conditional rows so the indices the
    /// engine navigates always line up with what's drawn.
    var focusItems: [String] {
        if collapsed { return ["Home", "Shorts", "Subscriptions", "You"] }
        var out = ["Home", "Shorts", "Subscriptions"]
        if store.account.signedIn && !store.account.subscriptions.isEmpty {
            let subs = store.account.subscriptions
            let shown = subsExpanded ? subs : Array(subs.prefix(subsCollapsedLimit))
            out += shown.map { $0.channelId.isEmpty ? $0.title : $0.channelId }
            if subs.count > subsCollapsedLimit { out.append("__more") }
        } else {
            let subs = store.subscriptions
            let shown = subsExpanded ? subs : Array(subs.prefix(subsCollapsedLimit))
            out += shown
            if subs.count > subsCollapsedLimit { out.append("__more") }
        }
        out += ["Your channel", "History", "Playlists", "Watch later", "Liked videos", "Your videos"]
        return out
    }
    private func focusTarget(_ key: String) -> FocusTarget? {
        focusItems.firstIndex(of: key).map { FocusTarget(.sidebar, $0) }
    }

    private func row(_ label: String, _ symbol: String) -> some View {
        Button {
            activateRow(label)
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
        .modifier(OptionalFocus(target: focusTarget(label), shape: .rect(10)) { activateRow(label) })
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
        .modifier(OptionalFocus(target: focusTarget(channelId ?? title), shape: .rect(10)) { if let cid = channelId, !cid.isEmpty { store.openChannel(cid) } })
    }

    private func monogram(_ name: String) -> some View {
        Circle().fill(channelColor(name).gradient)
            .overlay(Text(String(name.prefix(1))).font(.system(size: 11, weight: .bold)).foregroundColor(.white))
    }


    @ViewBuilder
    private func sectionHeader(_ title: String, trailing: String?, action: (() -> Void)? = nil) -> some View {
        let label = HStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let trailing { Image(systemName: trailing).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
        if let action {
            Button(action: action) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain).clickable()
        } else {
            label   // a genuine label: no chevron, nothing to click
        }
    }
}

// MARK: - Feed (chips + grid)

private struct FeedView: View {
    @EnvironmentObject var store: Store
    @Environment(\.gridContentWidth) private var gridW
    var search: String
    @Binding var selectedChip: String

    /// Filter chips derived from the channels ACTUALLY in the current feed. These used to be
    /// hardcoded categories keyed to the seeded demo catalog's channels ("Science" → Veritasium /
    /// Kurzgesagt, "Music" → Rick Astley…), which against a real personalized feed matched nothing
    /// and produced an empty grid.
    private var channelChips: [String] {
        var counts: [String: Int] = [:]
        for v in store.videos where !v.channel.isEmpty { counts[v.channel, default: 0] += 1 }
        return counts.filter { $0.value >= 2 }                       // only channels worth filtering to
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6).map(\.key)
    }

    private static let topAnchor = "feedTop"
    static let customFeedChip = "Your custom feed"
    /// Start the next page this many cards from the end, rather than on the very last one.
    ///
    /// Triggering only on the final card dead-ends: a card's onAppear fires ONCE when the lazy grid
    /// materialises it, and loadMore() bails while a request is in flight. If the new last card
    /// materialises before the previous load settles, that trigger is lost and — because the card
    /// stays materialised — onAppear never fires again, so scrolling silently stops loading. A lead
    /// means several cards can fire, so a lost one is recovered by the next.
    static let prefetchLead = 8
    @ObservedObject private var focusEngine = FocusEngine.shared

    /// Tell the focus engine how many cards are on screen and how wide a row is, so Up/Down move
    /// by exactly one visual row. Uses the SAME helper the layout uses, so they can't disagree.
    /// Scroll anchors for the grid cards.
    ///
    /// These MUST equal the identity each ForEach branch already uses. Attaching a `.id()` that
    /// DISAGREES replaces SwiftUI's identity with a positional one, and the cards then get recycled
    /// across a feed swap — @State and image included. That is precisely what broke search: the
    /// store held the right results while the grid went on rendering the previous home feed, so the
    /// heading read "Results for …" over unrelated videos. Keyboard focus needs an anchor to scroll
    /// to; it does not get to redefine what a card IS.
    private var gridAnchors: [String] {
        store.feedMode == "history" || store.feedMode == "playlist"
            ? shown.indices.map { "g\($0)" }        // per-position: these feeds may repeat a video
            : shown.map(\.id)                       // stable video-id identity
    }

    private func publishFocusGeometry() {
        focusEngine.setItems(.grid, shown.map(\.id))
        focusEngine.setItems(.chips, isSearch || store.feedHeading != nil ? [] : chipItems)
        focusEngine.setColumns(Grid3.columnCount(for: gridW))
        // Plex `previous_pivot_tab` / `next_pivot_tab` — the chips are this app's tabs. Clamped
        // rather than wrapping, matching how the arrows treat the row.
        let tabs = isSearch || store.feedHeading != nil ? [] : chipItems
        focusEngine.cycleTab = tabs.isEmpty ? nil : { [self] delta in
            let cur = tabs.firstIndex(of: selectedChip) ?? 0
            selectedChip = tabs[max(0, min(tabs.count - 1, cur + delta))]
        }
    }

    private var isSearch: Bool { !store.searchQuery.isEmpty }

    private var shown: [VideoListItem] {
        if isSearch { return store.videos }        // server-side results, unfiltered
        if store.feedHeading != nil { return store.videos }   // subs/history/playlist, unfiltered
        if selectedChip == "HDR" { return store.hdrVideos }   // curated HDR + feed-personalized picks
        if selectedChip == "All" { return store.videos }
        // "Your custom feed" is the slice from channels you actually subscribe to. It used to fall
        // through to the channel-name filter below and match nothing, so picking the FIRST chip in
        // the row emptied the grid. Falls back to the whole feed when there's no subscription list
        // to filter by (signed out), so it can never be empty-by-construction again.
        if selectedChip == Self.customFeedChip {
            let subs = Set(store.account.subscriptions.map(\.channelId))
            guard !subs.isEmpty else { return store.videos }
            let mine = store.videos.filter { $0.channelId.map(subs.contains) ?? false }
            return mine.isEmpty ? store.videos : mine
        }
        return store.videos.filter { $0.channel == selectedChip }
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
                    if store.feedMode == "playlist", Store.visionarySendablePlaylist(store.playlistId) {
                        VisionarySendButton(kind: "playlist",
                                            url: "https://www.youtube.com/playlist?list=\(store.playlistId)",
                                            title: heading)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        chip(Self.customFeedChip, icon: "square.grid.2x2")
                        chip("All", icon: nil)
                        chip("HDR", icon: "sun.max.fill")
                        ForEach(channelChips, id: \.self) { chip($0, icon: nil) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
            Divider().opacity(0.3)

            ScrollViewReader { proxy in
            ScrollView {
                // Zero-height anchor so navigating to a new destination can jump back to the top.
                Color.clear.frame(height: 0).id(Self.topAnchor)
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
                } else if shown.isEmpty, let why = store.feedUnavailable, !isSearch, store.feedHeading == nil {
                    // The feed is empty for a KNOWN reason. This used to render the seeded demo
                    // catalog instead — real-looking videos that were not the user's — so a decayed
                    // session or a transient failure was invisible. Say what happened.
                    if why == "signedOut" {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.circle").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text("Sign in to see your recommendations").font(.system(size: 14, weight: .medium))
                            Text("Your home feed comes from your YouTube account.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Sign in") { store.signIn() }.buttonStyle(.borderedProminent).clickable()
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 120)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text("Couldn't load your feed").font(.system(size: 14, weight: .medium))
                            Text("YouTube didn't return your recommendations just now.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Retry") { store.homeLoading = true; Task { await store.loadVideos() } }
                                .buttonStyle(.borderedProminent).clickable()
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 120)
                    }
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
                                Button { store.openItem(v) } label: {
                                    VideoCard(video: v, focusTarget: FocusTarget(.grid, idx))
                                }
                                    .buttonStyle(CardPress())
                                    .id("g\(idx)")          // == this branch's \.offset identity
                                    .onAppear {
                                        if idx >= shown.count - Self.prefetchLead { Task { await store.loadMore() } }
                                    }
                            }
                        } else {
                            // Stable video-id identity: chip switches / search swaps must NOT
                            // recycle a card's @State + image onto a different video.
                            ForEach(Array(shown.enumerated()), id: \.element.id) { idx, v in
                                Button { store.openItem(v) } label: {
                                    VideoCard(video: v, focusTarget: FocusTarget(.grid, idx))
                                }
                                    .buttonStyle(CardPress())
                                    .id(v.id)                // == this branch's \.element.id identity
                                    .onAppear {
                                        if idx >= shown.count - Self.prefetchLead { Task { await store.loadMore() } }
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
            // Any feed navigation (logo → Home, Subscriptions, History, …) starts at the top.
            .onChange(of: store.feedTopToken) { _, _ in
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
            // Keyboard navigation: publish what's on screen so the engine can do its index
            // arithmetic, and scroll the focused card in (the grid is lazy, so focus can move to a
            // row that isn't materialised yet).
            .onAppear { publishFocusGeometry(); VisionaryBridge.shared.refreshAvailability() }
            .onChange(of: shown.count) { _, _ in publishFocusGeometry() }
            .onChange(of: gridW) { _, _ in publishFocusGeometry() }
            .onChange(of: focusEngine.scrollTick) { _, _ in
                if let f = focusEngine.focused, f.zone == .grid, f.index < gridAnchors.count {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(gridAnchors[f.index], anchor: .center) }
                }
            }
            }   // end ScrollViewReader
        }
        .background(themeBackground(store.settings.theme))
        // Feedback result: undo affordance on success, a visible error when YouTube rejected it
        // (the card is put back in that case — it must never look like it worked).
        .overlay(alignment: .bottom) {
            if let u = store.feedbackUndo {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.label).font(.system(size: 13, weight: .semibold))
                        Text(u.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Button("Undo") { store.undoFeedback() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.24, green: 0.65, blue: 1))
                        .clickable()
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.12)))
                .background(RoundedRectangle(cornerRadius: 10).fill(themeBackground(store.settings.theme)))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let err = store.feedbackError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.12)))
                    .background(RoundedRectangle(cornerRadius: 10).fill(themeBackground(store.settings.theme)))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Probe for HDR when the HDR chip is picked, and again as the feed grows.
        .onChange(of: selectedChip) { _, v in if v == "HDR" { Task { await store.loadHDR() } } }
        .onChange(of: store.videos.count) { _, _ in
            if selectedChip == "HDR" { Task { await store.loadHDR() } }
            // A refreshed feed may no longer contain the filtered channel — don't strand the user
            // on a chip that now matches nothing.
            else if selectedChip != "All", !channelChips.contains(selectedChip) { selectedChip = "All" }
        }
    }

    private var isHDRTab: Bool { selectedChip == "HDR" && !isSearch && store.feedHeading == nil }

    /// The chips in visual order — the same list the engine navigates.
    private var chipItems: [String] { [Self.customFeedChip, "All", "HDR"] + channelChips }

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
        .modifier(OptionalFocus(target: chipItems.firstIndex(of: label).map { FocusTarget(.chips, $0) }, shape: .capsule) { selectedChip = label })
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
                HStack(spacing: 10) {
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
                    if let cid = store.channelInfo?.channelId, !cid.isEmpty {
                        VisionarySendButton(kind: "channel",
                                            url: "https://www.youtube.com/channel/\(cid)",
                                            title: store.channelInfo?.name ?? "")
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 16)
        .onAppear { seedSubscribed(); VisionaryBridge.shared.refreshAvailability() }
        .onChange(of: store.channelInfo?.channelId) { _, _ in
            seedSubscribed()
            store.applyPendingChannelTab(store.channelInfo?.tabs ?? [])
        }
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

    /// The channel's REAL tabs, from YouTube. This used to be three hardcoded labels — "Videos",
    /// "Playlists", "About" — drawn with a fixed `active:` flag and no button, so clicking them did
    /// nothing and the view was stuck on Videos. Now each tab is the one YouTube offers for THIS
    /// channel (a channel with no Shorts gets no Shorts tab) and carries its own browse params.
    /// "About" is gone because modern YouTube has no About tab — it's a dialog, not a tab.
    @ViewBuilder private var tabBar: some View {
        if let tabs = store.channelInfo?.tabs, !tabs.isEmpty {
            HStack(spacing: 28) {
                ForEach(tabs) { t in
                    tab(t.title, active: isActive(t)) { store.openChannelTab(t) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
    }

    /// Selected = the tab the user picked, or — before any pick — whichever YouTube marked selected.
    private func isActive(_ t: ChannelTabInfo) -> Bool {
        if let cur = store.channelTabParams { return cur == t.params }
        return t.selected
    }

    private func tab(_ label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(label).font(.system(size: 15, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                Rectangle().fill(active ? Color.primary : Color.clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
    }

    @ViewBuilder private var grid: some View {
        if store.channelInfo == nil || store.channelTabLoading {
            SkeletonVideoGrid()
        } else if store.videos.isEmpty {
            Text("Nothing here").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 80)
        } else {
            LazyVGrid(columns: Grid3.videoColumns(for: gridW), spacing: 28) {
                // Channel uploads are unique — stable id identity.
                // Enumerated for the index only — identity stays \.element.id, as before.
                ForEach(Array(store.videos.enumerated()), id: \.element.id) { idx, v in
                    // openItem, not openWatch: the Playlists tab is playlists, which open a
                    // playlist page rather than a watch page.
                    Button { store.openItem(v) } label: { VideoCard(video: v) }
                        .buttonStyle(CardPress())
                        .onAppear {
                            // Same prefetch lead as the feed: triggering on the last card alone
                            // dead-ends scrolling partway down a channel.
                            if idx >= store.videos.count - FeedView.prefetchLead {
                                Task { await store.loadMore() }
                            }
                        }
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
            Text("Sponsored placement — hidden automatically when Ad blocking is on.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(red: 1, green: 0, blue: 0.2), style: StrokeStyle(lineWidth: 1, dash: [5])))
    }
}

// MARK: - Video card

/// The card's 3-dot menu. The feedback rows are built from YouTube's OWN menu for that item
/// (labels and tokens come straight from the feed payload), so the app never offers an action
/// YouTube doesn't actually support for that card — and the wording always matches YouTube's.
/// Feeds differ: home offers "Not interested" + "Don't recommend channel", subscriptions offer
/// "Hide", history offers "Remove from watch history", and search offers none at all.
/// "Send to Visionary" for a playlist or channel page. Appears ONLY when Visionary's engine is
/// running here and its /api/state advertises the matching send capability — an engine that can't
/// receive collections never shows the button at all (hide inert UI, don't disable it).
private struct VisionarySendButton: View {
    @ObservedObject private var visionary = VisionaryBridge.shared
    let kind: String       // "playlist" | "channel" — must match a send_capabilities entry
    let url: String
    let title: String
    @State private var sending = false
    @State private var result: VisionaryBridge.SendResult?

    var body: some View {
        if visionary.canSend(kind) {
            Button {
                guard !sending else { return }
                sending = true; result = nil
                Task {
                    let r = await visionary.send(url: url, title: title)
                    sending = false
                    withAnimation(.easeOut(duration: 0.15)) { result = r }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation(.easeOut(duration: 0.2)) { result = nil }
                }
            } label: {
                Label(sending ? "Sending…" : (result?.label ?? "Send to Visionary"),
                      systemImage: result?.symbol ?? "arrow.up.square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(result?.isError == true ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.primary))
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).clickable()
            .disabled(sending)
        }
    }
}

private struct VideoCardMenu: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var visionary = VisionaryBridge.shared
    let video: VideoListItem
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(video.feedback) { option in
                row(option.label, option.symbol) {
                    store.applyFeedback(video, option)
                }
            }
            if !video.feedback.isEmpty { Divider().opacity(0.25) }
            row("Copy link", "link") {
                store.copyToPasteboard(video.webURL)
            }
            // Hidden once it's been marked this session rather than shown inert — a row that
            // does nothing when clicked is exactly the decorative UI this pass is removing.
            if video.playlistId == nil, !store.isMarkedWatched(video.id) {
                row("Mark as watched", "checkmark.circle") { store.markWatchedFromMenu(video) }
            }
            // Every card kind can be sent, each as its own Visionary capability: a playlist card
            // sends the playlist, a video or Short sends the video. Still gated on canSend, so a
            // kind Visionary can't receive shows no row at all.
            if visionary.canSend(video.playlistId != nil ? "playlist" : "video") {
                row("Send to Visionary", "arrow.up.square") {
                    store.sendToVisionary(url: video.webURL, title: store.title(for: video))
                }
            }
            if let cid = video.channelId, !cid.isEmpty {
                row("Go to channel", "person.crop.circle") { store.openChannel(cid) }
            }
            row("Open in YouTube", "arrow.up.forward.square") {
                store.openURL(video.webURL)
            }
        }
        .padding(6)
        .frame(width: 246)
    }

    private func row(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle()).clickable()
    }
}

/// Subtle hover fill for menu rows, matching the app's elevation ladder.
private struct HoverRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.10 : 0)))
            .onHover { hover = $0 }
    }
}

private struct VideoCard: View {
    @EnvironmentObject var store: Store
    let video: VideoListItem
    /// Where this card sits in the keyboard-focus order. Optional so callers that don't take part
    /// in focus (skeletons, previews) are unaffected.
    var focusTarget: FocusTarget? = nil
    @ObservedObject private var focusEngine = FocusEngine.shared
    @State private var hover = false
    @State private var channelHover = false
    @State private var showMenu = false
    // Hover-to-preview state.
    @State private var previewOn = false
    @State private var clip: PreviewClip? = nil
    @State private var hoverTask: Task<Void, Never>? = nil

    /// True only while the keyboard is driving AND this card is the focused one.
    private var keyFocused: Bool { focusTarget.map { focusEngine.isFocused($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
            HStack(alignment: .top, spacing: 12) {
                if !video.channel.isEmpty { channelAvatar }
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.title(for: video))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !video.channel.isEmpty { channelLine }
                    Text(metaLine).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // 3-dot overflow menu. Button + popover rather than SwiftUI `Menu`: an image-labelled
                // Menu gets rendered through AppKit menu chrome that mangles the label (same trap
                // that broke the account avatar).
                if hover || showMenu || keyFocused {
                    Button { showMenu.toggle() } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.primary.opacity(showMenu ? 0.12 : 0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).clickable()
                    .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                        VideoCardMenu(video: video, dismiss: { showMenu = false })
                            .environmentObject(store)
                    }
                }
            }
        }
        // Plex `menu`: M (or a long Return) asks the FOCUSED card to open its overflow popover.
        .onChange(of: focusEngine.menuTarget) { _, target in
            guard let target, let mine = focusTarget, target == mine else { return }
            focusEngine.clearMenu()
            showMenu = true
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
            // Drawn only when YouTube actually says so. This badge used to render unconditionally,
            // which marked every channel in the app as verified.
            if video.verified { Image(systemName: "checkmark.seal.fill").font(.system(size: 10)) }
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
            } else if let c = video.videoCountText {
                // Playlist result: YouTube's own count badge where a video shows its duration.
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack.fill").font(.system(size: 9))
                    Text(c).font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.black.opacity(0.8)).foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(8)
            }
        }
        // Keyboard focus reuses this exact hover stroke, just in the accent the focused search
        // field already uses — so a focused card reads like a hovered one and nothing is restyled.
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(keyFocused ? Color(red: 0.24, green: 0.65, blue: 1) : Color.primary.opacity(hover ? 0.25 : 0),
                    lineWidth: keyFocused ? 2 : 1))
    }

    /// The card's metadata line — ONLY real values.
    ///
    /// This used to fall back to pseudoMeta(), which picked a view count and an upload date out of
    /// hard-coded lists using the video id's hash, and rendered them exactly like real ones: a card
    /// with no metadata claimed "834K views · 2 days ago". Stable per id, so it looked entirely
    /// convincing and never even flickered. Where YouTube gives nothing, the line is now empty —
    /// an absent fact beats an invented one.
    private var metaLine: String {
        if video.playlistId != nil { return video.publishedText ?? "Playlist" }
        return [video.viewCountText, video.publishedText]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

// MARK: - Logo

struct CommentRow: View {
    @EnvironmentObject var store: Store
    let comment: Comment
    /// The user's REAL vote on this comment. Seeded from YouTube and written back through
    /// /api/comment/vote — this used to be annotated "(visual only)": the thumbs filled in and
    /// nothing was ever sent, so a liked comment silently reverted on the next page load.
    @State private var likeState = 0
    @State private var seeded = false
    @State private var busy = false
    @State private var repliesOpen = false
    @State private var replies: [Comment] = []
    @State private var loadingReplies = false

    /// The vote to send for a tap, given where we are now. YouTube ships a distinct token for each
    /// transition, including the two "undo" ones.
    private func token(for target: Int) -> String {
        if target == 0 { return likeState == 1 ? comment.unlikeToken : comment.undislikeToken }
        return target == 1 ? comment.likeToken : comment.dislikeToken
    }
    private var canVote: Bool { !comment.likeToken.isEmpty || !comment.dislikeToken.isEmpty }

    private func vote(_ target: Int) {
        guard !busy else { return }
        let tok = token(for: target)
        guard !tok.isEmpty else { return }
        let previous = likeState
        busy = true
        withAnimation(.easeOut(duration: 0.1)) { likeState = target }
        Task {
            let ok = await store.voteComment(token: tok)
            busy = false
            guard !ok else { return }
            withAnimation(.easeOut(duration: 0.15)) { likeState = previous }   // never fake a vote
            store.actionNote = "Couldn't vote on that comment"
            store.actionNoteIsError = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { store.actionNote = nil }
        }
    }

    /// YouTube ships the count for both states, so the number flips without refetching.
    private var likeCountText: String {
        if likeState == 1, !comment.likesLiked.isEmpty { return comment.likesLiked }
        return comment.likes.isEmpty ? "0" : comment.likes
    }

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
                    // Hidden when YouTube offered no tokens (signed out): controls that cannot
                    // work shouldn't be drawn.
                    if canVote {
                        Button { vote(likeState == 1 ? 0 : 1) } label: {
                            Label(likeCountText,
                                  systemImage: likeState == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .foregroundStyle(likeState == 1 ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                        }.buttonStyle(.plain).clickable().disabled(busy)
                        Button { vote(likeState == -1 ? 0 : -1) } label: {
                            Image(systemName: likeState == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .foregroundStyle(likeState == -1 ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                        }.buttonStyle(.plain).clickable().disabled(busy)
                    } else {
                        Label(comment.likes.isEmpty ? "0" : comment.likes, systemImage: "hand.thumbsup")
                            .foregroundStyle(.secondary)
                    }
                    // "N replies" was a plain label sitting exactly where YouTube puts its reply
                    // expander, inside a row of working controls. It expands now — when YouTube
                    // gave a token for it; otherwise it stays a label rather than a dead button.
                    if !comment.replies.isEmpty {
                        if comment.repliesToken.isEmpty {
                            Text("\(comment.replies) replies").foregroundStyle(.secondary)
                        } else {
                            Button {
                                repliesOpen.toggle()
                                guard repliesOpen, replies.isEmpty, !loadingReplies else { return }
                                loadingReplies = true
                                Task {
                                    replies = await store.loadReplies(token: comment.repliesToken)
                                    loadingReplies = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: repliesOpen ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("\(comment.replies) replies")
                                }
                                .foregroundStyle(Color(red: 0.24, green: 0.65, blue: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).clickable()
                        }
                    }
                }
                .font(.system(size: 12))
                .onAppear {
                    // Seed once from YouTube's real state; never clobber a vote in flight.
                    guard !seeded else { return }
                    seeded = true
                    likeState = comment.likeState
                }
                if repliesOpen {
                    if loadingReplies && replies.isEmpty {
                        ProgressView().controlSize(.small).padding(.top, 6)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(replies) { r in CommentRow(comment: r).environmentObject(store) }
                        }
                        .padding(.top, 10).padding(.leading, 8)
                    }
                }
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
