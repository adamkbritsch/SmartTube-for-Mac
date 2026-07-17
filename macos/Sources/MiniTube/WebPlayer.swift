import SwiftUI
import WebKit
import AppKit

/// A WKWebView that hands scroll-wheel events to the enclosing scroll view instead of
/// eating them, so the page keeps scrolling while the pointer is over the player. The
/// player page is cropped to just the video (overflow hidden, nothing to scroll), so
/// forwarding every wheel event loses nothing. Fixes: hovering the video froze scrolling.
final class ScrollThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Nearest NSScrollView ancestor — SwiftUI's ScrollView is backed by one
        // (HostingScrollView, verified in the live superview chain).
        var v: NSView? = superview
        while let cur = v {
            if let sv = cur as? NSScrollView { sv.scrollWheel(with: event); return }
            v = cur.superview
        }
        // No scroll view above us (e.g. reparented into WebKit's fullscreen window):
        // let the web content handle the wheel normally.
        super.scrollWheel(with: event)
    }
}

/// Hosts the player web view. SwiftUI sizes THIS container; the web view fills it via
/// layout(). WebKit REPARENTS the web view into its own WebCoreFullScreenWindow for
/// YouTube's element fullscreen — when makeNSView returned the web view directly,
/// SwiftUI kept setting the reparented web view's frame back to the embedded size on
/// every layout pass, shrinking the fullscreen video to a tiny rectangle in the
/// lower-left of a black screen (verified with the debug render/native probes:
/// wvFrame 1728x1084 → 654x368 while still inside WebCoreFullScreenWindow). SwiftUI
/// only ever touches the container, so the fullscreen web view keeps the frame WebKit
/// gives it; on exit WebKit restores the web view here and layout() re-fills it.
final class PlayerContainer: NSView {
    let webView: ScrollThroughWebView
    init(webView: ScrollThroughWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
    }
    required init?(coder: NSCoder) { fatalError("PlayerContainer is code-only") }

    private func fillWebView() {
        // Never touch the web view while WebKit has it borrowed for fullscreen.
        if webView.superview == self { webView.frame = bounds }
    }
    override func layout() { super.layout(); fillWebView() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); fillWebView() }
    // WebKit re-adds the web view here when fullscreen exits — snap it back to our size.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview === webView { fillWebView(); needsLayout = true }
    }
}

extension WKWebsiteDataStore {
    /// In-memory, cookie-less store: the player runs real youtube.com LOGGED OUT
    /// (the rest of the app stays personalized via the backend/InnerTube session).
    static let player = WKWebsiteDataStore.nonPersistent()
}

/// Loads the REAL youtube.com watch page (not the embed), cropped to just the player,
/// and injects SponsorBlock + ad-skip so those still work on YouTube's own player.
struct WebPlayer: NSViewRepresentable {
    let videoId: String
    var adBlock: Bool = true
    var sponsorBlock: Bool = true
    var maxResolution: Bool = true      // force highest available source resolution
    var enhance: String = "subtle"      // GPU sharpen preset: "off" | "subtle" | "sharper"
    var gpuSaver: Bool = false          // Visionary running → shed the Enhance filter (resolution unaffected)
    var playbackSpeed: Double = 1.0     // player rate (1 / 1.25 / 1.5 / 1.75 / 2)
    var autoFullscreen: Bool = false    // auto-enter YouTube fullscreen when a video starts
    var sbCategories: [String] = Settings.sbAllCategories       // SponsorBlock categories to skip
    var adPruneKeys: [String] = AdRules.fallback.pruneKeys      // uBO json-prune keys (object delete)
    var adScrubKeys: [String] = AdRules.fallback.scrubKeys      // uBO keys (response-text rename)
    var onFullscreen: () -> Void = {}
    var onEnhanceInfo: (Int, Double, Bool) -> Void = { _, _, _ in }   // (playing height, sharpen amount, isHDR)
    var onEnded: () -> Void = {}                                       // video finished (autoplay hook)
    var onTheater: () -> Void = {}                                     // YouTube's own theater button was clicked
    var onMarkWatched: (String) -> Void = { _ in }                    // watched past threshold → log to YouTube history

    /// Whether to wire the uBO/SponsorBlock WKWebExtension into the player WebView. OFF by default:
    /// the extension currently hangs the watch-page load on this WebKit (see makeNSView). Native
    /// blockers cover the gap. Set MT_PLAYER_EXT=1 to opt back in and retest once WebKit is fixed.
    static let playerUsesExtension = ProcessInfo.processInfo.environment["MT_PLAYER_EXT"] == "1"

    func makeNSView(context: Context) -> PlayerContainer {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true       // YouTube's own fullscreen button
        // Share the extension controller's store when it exists — WKWebExtension only injects
        // content scripts into WebViews on the controller's OWN data store. Attach the controller
        // and use its store together; fall back to the standalone cookie-less store when
        // extensions are unavailable (macOS < 15.4).
        // The uBO/SponsorBlock WKWebExtension deterministically HANGS this player's main-frame
        // navigation to youtube.com/watch — the provisional load never commits, so the video never
        // appears (bisected: Tests A/B/D hang with the controller+store attached; Test C, detached,
        // loads + plays 4K normally). The extension loads without errors, so this is a macOS/WebKit
        // regression in main-frame handling, not our code. The app's NATIVE stack fully covers the
        // gap: in-page adBlockJS + cancelPlayback kill ads, the JS SponsorBlock re-arms automatically
        // (nativeSB=false below), DeArrow comes from the backend — and the player crops YouTube's
        // chrome away, so uBO's cosmetic filtering was invisible here regardless. Opt back in with
        // MT_PLAYER_EXT=1 to retest once WebKit fixes this.
        if #available(macOS 15.4, *), WebPlayer.playerUsesExtension, let controller = UBlockLoader.shared.controller {
            config.websiteDataStore = UBlockLoader.shared.dataStore ?? .player
            config.webExtensionController = controller
        } else {
            config.websiteDataStore = .player
        }
        config.userContentController.add(context.coordinator, name: "minitube")
        // flags FIRST at documentStart: the engine/enhance loops read window.__MT the
        // instant they start, so a user's disabled features are never transiently on.
        WebPlayer.installScripts(into: config.userContentController, flags: flagsJS)

        // Consent cookie so logged-out YouTube doesn't wall playback behind a consent page.
        for domain in [".youtube.com", ".google.com"] {
            if let c = HTTPCookie(properties: [.domain: domain, .path: "/", .name: "SOCS", .value: "CAI",
                                               .expires: Date(timeIntervalSinceNow: 31_536_000)]) {
                config.websiteDataStore.httpCookieStore.setCookie(c)
            }
        }

        let webView = ScrollThroughWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.latestFlags = flagsJS
        // Desktop-Chrome-on-macOS UA — the field-proven WebKit spoof: removes YouTube's
        // Safari-only AVC/1080p downgrade (so HDR appears) AND streams normally. A Firefox
        // UA on WebKit served a broken path that hard-capped the forward buffer at ~60s;
        // Chrome is the matched/expected combo. UA has NO effect on ads (verified 4×).
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        // Register this WebView as the extension host tab BEFORE loading, so a content
        // script's runtime.sendMessage resolves (SponsorBlock's skip/config/segment fetch
        // all route through the background page — without a tab it fails "Tab not found").
        if #available(macOS 15.4, *), WebPlayer.playerUsesExtension { UBlockLoader.shared.attachPlayer(webView) }
        // Host-driven ad skip: dismiss adSlots video ads via the player's cancelPlayback() (the
        // only reliable path since stripping adSlots from the response would freeze forward seeks).
        context.coordinator.startAdSkip(webView)
        // Sign the WebView into YouTube with the user's Firefox cookies BEFORE the first load, so
        // playback is attested and far-forward seeks work (signed-out YouTube is SABR-throttled and
        // can't jump to a distant position — verified). Read off-main; the initial load is gated on
        // completion. No Firefox login → empty set → normal signed-out playback.
        let coordinator = context.coordinator
        let store = config.websiteDataStore
        DispatchQueue.global(qos: .userInitiated).async {
            let cookies = FirefoxCookies.load()
            DispatchQueue.main.async {
                guard !cookies.isEmpty else { coordinator.signInDidComplete(); return }
                let group = DispatchGroup()
                for c in cookies { group.enter(); store.httpCookieStore.setCookie(c) { group.leave() } }
                group.notify(queue: .main) {
                    Coordinator.debugLog("player signed in — \(cookies.count) YouTube/Google cookies installed")
                    coordinator.signInDidComplete()
                }
            }
        }
        return PlayerContainer(webView: webView)
    }

    /// The window.__MT flag object the injected loops read. Includes nativeSB so the JS
    /// SponsorBlock stands down when the real SponsorBlock extension is loaded (no double-skip).
    private var flagsJS: String {
        // nativeSB stands the JS SponsorBlock down ONLY when the real extension is actually wired
        // into this player. Since the player detaches the extension (see makeNSView), this is false,
        // so the JS SponsorBlock runs and community segments still skip.
        var nativeSB = false
        if #available(macOS 15.4, *) { nativeSB = WebPlayer.playerUsesExtension && UBlockLoader.shared.contexts["SponsorBlock"] != nil }
        // Ad keys + categories ride in as JSON ARRAYS (data), re-filtered here so nothing but
        // safe tokens ever reaches the page — never string-concatenated into JS source.
        let prune = WebPlayer.jsArray(adPruneKeys, allow: WebPlayer.keyRegex)
        let scrub = WebPlayer.jsArray(adScrubKeys, allow: WebPlayer.keyRegex)
        let cats = WebPlayer.jsArray(sbCategories, allow: WebPlayer.catRegex)
        return "window.__MT={adBlock:\(adBlock),sponsorBlock:\(sponsorBlock),maxResolution:\(maxResolution),enhance:'\(enhance)',playbackSpeed:\(playbackSpeed),autoFullscreen:\(autoFullscreen),nativeSB:\(nativeSB),gpuSaver:\(gpuSaver),adPruneKeys:\(prune),adScrubKeys:\(scrub),sbCategories:\(cats),debug:\(MTDebug.enabled)};"
    }

    private static let keyRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{2,64}$")
    private static let catRegex = try! NSRegularExpression(pattern: "^[a-z_]{3,32}$")

    /// Serialize a string array to a JS array literal, keeping only items matching `allow`
    /// and capping at 32. JSONSerialization escapes safely — but since the regex already
    /// restricts to alnum/_/- there is nothing dangerous to embed.
    static func jsArray(_ items: [String], allow: NSRegularExpression) -> String {
        let safe = items.filter { s in
            allow.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }.prefix(32)
        guard let data = try? JSONSerialization.data(withJSONObject: Array(safe)),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    func updateNSView(_ container: PlayerContainer, context: Context) {
        let webView = container.webView
        context.coordinator.load(videoId, into: webView)
        // Only act when the flags actually changed — updateNSView fires on every parent
        // re-render (incl. the player's own readouts), which used to re-eval JS in a loop.
        let flags = flagsJS
        guard flags != context.coordinator.latestFlags else { return }
        context.coordinator.latestFlags = flags
        // Future navigations: rebuild the documentStart scripts with the new flags.
        WebPlayer.installScripts(into: webView.configuration.userContentController, flags: flags)
        // Current page: push the full object live (partial would wipe other fields).
        webView.evaluateJavaScript(flags, completionHandler: nil)
    }

    /// The documentStart script stack, flags first. Rebuilt whenever settings change.
    static func installScripts(into ucc: WKUserContentController, flags: String) {
        ucc.removeAllUserScripts()
        // adBlockJS runs right after the flags so uBO's json-prune hooks are installed
        // before YouTube's player scripts read the ad payload.
        for src in [flags, adBlockJS, cropJS, engineJS, enhanceJS] {
            ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    // Stop audio the instant this player's view is removed.
    static func dismantleNSView(_ container: PlayerContainer, coordinator: Coordinator) {
        coordinator.stopAdSkip()
        container.webView.pauseAllMediaPlayback(completionHandler: nil)
        container.webView.loadHTMLString("", baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFullscreen: onFullscreen, onEnhanceInfo: onEnhanceInfo, onEnded: onEnded, onTheater: onTheater, onMarkWatched: onMarkWatched, adBlock: adBlock, sponsorBlock: sponsorBlock) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onFullscreen: () -> Void
        private let onEnhanceInfo: (Int, Double, Bool) -> Void
        private let onEnded: () -> Void
        private let onTheater: () -> Void
        private let onMarkWatched: (String) -> Void
        let adBlock: Bool
        let sponsorBlock: Bool
        var latestFlags = ""       // current window.__MT — re-pushed after each page load
        private var loaded: String?
        // Native ad-skip driver. adSlots-scheduled video ads CAN'T be stripped from the player
        // response without freezing forward seeks (the SABR player re-reads adSlots at seek time),
        // so the ad still starts — we dismiss it by calling the player's own cancelPlayback() the
        // instant it enters an ad. This ONLY works when invoked from the host (evaluateJavaScript);
        // the identical call from an injected page-timer is silently ignored (no user-activation),
        // which is why this lives here and not in adBlockJS.
        private weak var adSkipWebView: WKWebView?
        private var adSkipTimer: Timer?

        init(onFullscreen: @escaping () -> Void, onEnhanceInfo: @escaping (Int, Double, Bool) -> Void, onEnded: @escaping () -> Void, onTheater: @escaping () -> Void, onMarkWatched: @escaping (String) -> Void, adBlock: Bool, sponsorBlock: Bool) {
            self.onFullscreen = onFullscreen; self.onEnhanceInfo = onEnhanceInfo; self.onEnded = onEnded; self.onTheater = onTheater; self.onMarkWatched = onMarkWatched
            self.adBlock = adBlock; self.sponsorBlock = sponsorBlock
        }

        // Sign-in gate: the very first load waits until the Firefox auth cookies are installed
        // (see makeNSView) so playback is attested — a signed-OUT session is SABR-throttled and
        // can't far-forward-seek. load() records the desired video and no-ops until ready; the
        // cookie completion calls signInDidComplete() to flush it. Video CHANGES afterward load
        // normally (cookies already in the store, ready==true).
        var signInReady = false
        private var desiredVideo: String?
        private weak var desiredWebView: WKWebView?

        func load(_ videoId: String, into webView: WKWebView) {
            desiredVideo = videoId; desiredWebView = webView
            guard signInReady, loaded != videoId,
                  let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else {
                // Only the still-waiting-on-sign-in case is interesting; skip the every-render
                // re-calls after the video is already loaded (they'd flood the debug log).
                if loaded != videoId { MTDebug.log("[load] waiting v=\(videoId) signInReady=\(signInReady)") }
                return
            }
            loaded = videoId
            MTDebug.log("[load] firing v=\(videoId)")
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }

        func signInDidComplete() {
            signInReady = true
            MTDebug.log("[signin] complete; desiredVideo=\(desiredVideo ?? "nil")")
            if let v = desiredVideo, let w = desiredWebView { load(v, into: w) }
        }

        // Navigation diagnostics (no-op unless /tmp/mt-debug present) — surface silent load failures.
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
            MTDebug.log("[nav] start \(w.url?.absoluteString ?? "nil")")
        }
        func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
            MTDebug.log("[nav] commit \(w.url?.absoluteString ?? "nil")")
        }
        func webView(_ w: WKWebView, didReceiveServerRedirectForProvisionalNavigation n: WKNavigation!) {
            MTDebug.log("[nav] redirect \(w.url?.absoluteString ?? "nil")")
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            MTDebug.log("[nav] finish \(w.url?.absoluteString ?? "nil")")
        }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            MTDebug.log("[nav] FAIL-provisional \(e.localizedDescription)")
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
            MTDebug.log("[nav] FAIL \(e.localizedDescription)")
        }

        // Flags now ride in as the FIRST documentStart user script (rebuilt on every
        // settings change), so each navigation starts with the real values — no
        // post-load re-push needed, and no defaults flash before it lands.

        /// Begin the host-driven player poll (~0.5s): cancel a starting ad AND auto-enter fullscreen.
        /// Both ticks re-check their live __MT flag, so toggling either setting governs it without
        /// tearing down the timer. Both must run from the host (evaluateJavaScript) — the identical
        /// calls from an in-page timer are ignored (ad cancelPlayback and the Fullscreen API both
        /// need host/user activation).
        func startAdSkip(_ webView: WKWebView) {
            adSkipWebView = webView
            adSkipTimer?.invalidate()
            adSkipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak webView] _ in
                webView?.evaluateJavaScript(WebPlayer.adSkipTick, completionHandler: nil)
                webView?.evaluateJavaScript(WebPlayer.autoFullscreenTick, completionHandler: nil)
            }
        }
        func stopAdSkip() { adSkipTimer?.invalidate(); adSkipTimer = nil }
        deinit { adSkipTimer?.invalidate() }

        /// Diagnostics go through the central debug gate — a normal run writes nothing.
        static func debugLog(_ msg: String) { MTDebug.log(msg) }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["action"] as? String {
            case "fullscreen":
                onFullscreen()
            case "enhance":
                let h = (body["height"] as? Int) ?? Int((body["height"] as? Double) ?? 0)
                let a = (body["amount"] as? Double) ?? 0
                let hdr = (body["hdr"] as? Bool) ?? false
                onEnhanceInfo(h, a, hdr)
            case "theater":
                onTheater()
            case "ended":
                onEnded()
            case "markWatched":
                if let vid = body["videoId"] as? String, !vid.isEmpty { onMarkWatched(vid) }
            case "hdrcap":
                // Ground truth on whether this WebView can decode HDR at all.
                let av1 = (body["av1"] as? Bool) ?? false
                let vp9 = (body["vp9"] as? Bool) ?? false
                let display = (body["display"] as? Bool) ?? false
                Coordinator.debugLog("HDR capability — AV1:\(av1) VP9.2:\(vp9) display-HDR:\(display)")
            case "buf":
                let t = body["t"] ?? "?", end = body["end"] ?? "?"
                let rs = body["rs"] ?? "?", paused = body["paused"] ?? "?", q = body["q"] ?? "?"
                Coordinator.debugLog("buf t=\(t)s buffered-to=\(end)s readyState=\(rs) paused=\(paused) q=\(q)")
            case "render":
                if let e = body["err"] { Coordinator.debugLog("render ERR \(e)") }
                else {
                    let vr = body["vrect"] ?? "?", vw = body["vw"] ?? "?", inner = body["inner"] ?? "?"
                    let f = body["filter"] ?? "?", op = body["opacity"] ?? "?", vis = body["vis"] ?? "?"
                    let disp = body["disp"] ?? "?", tr = body["transform"] ?? "?", mb = body["mixblend"] ?? "?"
                    let pbg = body["pbg"] ?? "?", ppos = body["ppos"] ?? "?", hit = body["hit"] ?? "?"
                    let fs = body["fs"] ?? "?"
                    Coordinator.debugLog("render fs=\(fs) vrect=\(vr) vpx=\(vw) inner=\(inner) filter=\(f) opacity=\(op) vis=\(vis) disp=\(disp) transform=\(tr) mixblend=\(mb) mpBg=\(pbg) mpPos=\(ppos) hit=\(hit)")
                    // Native side of the same snapshot: the web view's actual frame, which
                    // window hosts it (WebKit reparents it for element fullscreen), and the
                    // superview chain (is there an NSScrollView for scroll forwarding?).
                    if let wv = adSkipWebView {
                        var chain: [String] = []
                        var v: NSView? = wv.superview
                        while let cur = v, chain.count < 14 { chain.append(String(describing: type(of: cur))); v = cur.superview }
                        let win = wv.window
                        let wf = win?.frame ?? .zero
                        let winName = win.map { String(describing: type(of: $0)) } ?? "nil"
                        Coordinator.debugLog("native wvFrame=\(Int(wv.frame.width))x\(Int(wv.frame.height))@\(Int(wv.frame.minX)),\(Int(wv.frame.minY)) window=\(winName) \(Int(wf.width))x\(Int(wf.height)) chain=\(chain.joined(separator: " > "))")
                    }
                }
            case "admute":
                let on = (body["on"] as? Bool) ?? false
                let why = (body["why"] as? String) ?? (on ? "ad-detected" : "")
                Coordinator.debugLog("admute \(on ? "MUTE" : "restore") \(why)")
            case "adcfg":
                let prune = (body["prune"] as? [String]) ?? []
                let scrub = (body["scrub"] as? [String]) ?? []
                let cats = (body["cats"] as? [String]) ?? []
                Coordinator.debugLog("adcfg prune=\(prune) scrub=\(scrub) cats=\(cats)")
            default:
                break
            }
        }
    }

    // MARK: injected scripts

    /// Hide all of youtube.com's chrome and blow the player up to fill the view.
    static let cropJS = """
    (function(){
      var css = `
        #masthead-container, ytd-masthead, #secondary, #secondary-inner, #below, #comments, ytd-comments,
        #chat, ytd-watch-metadata, #guide, ytd-mini-guide-renderer, tp-yt-app-drawer,
        ytd-merch-shelf-renderer, .ytp-pause-overlay, .ytp-ce-element, .ytp-endscreen-content,
        ytd-engagement-panel-section-list-renderer, #donation-shelf, ytd-popup-container tp-yt-paper-dialog { display:none !important; }
        html, body, ytd-app, #content.ytd-app, ytd-page-manager, #page-manager { margin:0 !important; padding:0 !important; overflow:hidden !important; background:#000 !important; height:100% !important; }
        /* Force ONLY the player element to fill the viewport (fixed escapes its
           ancestors' clipping). Do NOT position its ancestors — a fixed transparent
           ancestor would layer over the player and swallow all mouse clicks. */
        #movie_player {
          position: fixed !important; top:0 !important; left:0 !important; right:0 !important; bottom:0 !important;
          width:100vw !important; height:100vh !important; margin:0 !important; padding:0 !important; z-index: 2147483000 !important; }
        /* object-fit:contain — forcing the element to fill the box makes content
           scale cover-style otherwise: fullscreen on a 16:10 screen cropped ~11%
           off the sides of every 16:9 video; cinematic content cropped windowed. */
        .html5-video-container, video.html5-main-video { width:100% !important; height:100% !important; left:0 !important; top:0 !important; object-fit: contain !important; }
      `;
      function apply(){ var s=document.getElementById('mt-crop'); if(!s){ s=document.createElement('style'); s.id='mt-crop'; s.textContent=css; (document.head||document.documentElement).appendChild(s); } }
      apply();
      // Insert the crop <style> as soon as <head> exists, then stop observing (the
      // rule is global + idempotent — no need to watch YouTube's churny DOM all session).
      var _co = new MutationObserver(function(){ apply(); if(document.getElementById('mt-crop')) _co.disconnect(); });
      _co.observe(document.documentElement, { childList:true, subtree:true });
      // nudge the player to resize into the new box a few times after load, then STOP
      // (dispatching resize forever every 1.5s can disrupt the player's buffering).
      var __rc = 0, __ri = setInterval(function(){ try { window.dispatchEvent(new Event('resize')); } catch(e){} if(++__rc >= 6) clearInterval(__ri); }, 1000);

      // YouTube's own "Theater mode" control (.ytp-size-button, the rectangle left of
      // fullscreen) is meaningless in the cropped player. Intercept it in the capture
      // phase (before YouTube's handler) and drive the APP's theater instead.
      document.addEventListener('click', function(e){
        var t = e.target;
        var btn = t && t.closest && t.closest('.ytp-size-button');
        if(btn){
          e.preventDefault(); e.stopImmediatePropagation();
          try { window.webkit.messageHandlers.minitube.postMessage({action:'theater'}); } catch(err){}
        }
      }, true);
    })();
    """

    /// Full ad-strip — uBlock Origin's json-prune of the YouTube ad keys from the player
    /// response, so NO ad is ever scheduled or played (no flash, nothing to skip). The key
    /// list is DATA-DRIVEN from __MT.adPruneKeys / __MT.adScrubKeys (served by the backend from
    /// uBO's live upstream rules), with the classic triple as fallback — so when YouTube changes
    /// ad delivery, uBO's upstream fix flows in with no app update. Stripping `adSlots` is safe
    /// because the player runs SIGNED IN (see makeNSView / FirefoxCookies): the earlier "deleting
    /// adSlots freezes forward seeks" was the SIGNED-OUT SABR throttle, not the ad keys. Surfaces:
    ///   • inline `ytInitialPlayerResponse` (fresh watch-page load) — delete the keys post-parse.
    ///   • fetch()/XHR `/player` responses (SPA nav) — rename the keys in the raw response TEXT
    ///     before parse, uBO-style, so that object is born ad-free.
    /// The Coordinator's cancelPlayback timer stays as a backstop. Injected FIRST at documentStart.
    /// Gated on __MT.adBlock. Keys are re-read each call so a live flag push takes effect.
    static let adBlockJS = """
    (function(){
      if(!window.__MT) window.__MT = { adBlock:true };
      if(window.__mtAdPrune) return; window.__mtAdPrune = true;
      var KRE = /^[A-Za-z0-9_-]{2,64}$/;
      var FALLBACK = ['adPlacements','playerAds','adSlots'];
      function pKeys(){ var k = window.__MT.adPruneKeys; k = (k && k.length) ? k : FALLBACK; return k.filter(function(x){ return typeof x==='string' && KRE.test(x); }); }
      function sKeys(){ var k = window.__MT.adScrubKeys; k = (k && k.length) ? k : FALLBACK; return k.filter(function(x){ return typeof x==='string' && KRE.test(x); }); }
      function strip(o){
        try {
          if(!window.__MT.adBlock || !o || typeof o !== 'object') return o;
          if(Array.isArray(o)){ for(var i=0;i<o.length;i++) strip(o[i]); return o; }
          var ks = pKeys();
          for(var j=0;j<ks.length;j++){ if(ks[j] in o) delete o[ks[j]]; }
          if(o.playerResponse && typeof o.playerResponse === 'object') strip(o.playerResponse);
        } catch(e){}
        return o;
      }
      // Rename ad keys in raw response text so the parsed object is born ad-free. Rebuild the
      // combined regex only when the key set changes (keys are alnum-only → nothing to escape).
      var _sig = null, _re = null;
      function scrubRe(){ var ks = sKeys(); var sig = ks.join('|'); if(sig !== _sig){ _sig = sig; _re = sig ? new RegExp('"(' + sig + ')"', 'g') : null; } return _re; }
      function scrub(t){
        if(!window.__MT.adBlock || typeof t !== 'string') return t;
        var re = scrubRe(); if(!re) return t;
        var ks = sKeys(), hit = false;
        for(var i=0;i<ks.length;i++){ if(t.indexOf('"'+ks[i]+'"') >= 0){ hit = true; break; } }
        if(!hit) return t;
        return t.replace(re, '"no_ads"');
      }
      // DEBUG-only: report the active config, and re-report whenever the live key/category set
      // changes (a flag live-push landing), so headless runs can confirm server-delivered keys.
      try { if(window.__MT.debug){ var _cfg=''; setInterval(function(){
        var sig = pKeys().join(',')+'|'+sKeys().join(',')+'|'+((window.__MT.sbCategories||[]).join(','));
        if(sig!==_cfg){ _cfg=sig; try { window.webkit.messageHandlers.minitube.postMessage({action:'adcfg', prune: pKeys(), scrub: sKeys(), cats: (window.__MT.sbCategories||[])}); } catch(e){} }
      }, 1000); } } catch(e){}
      function wanted(u){ u = u || ''; return u.indexOf('/youtubei/') !== -1 || u.indexOf('/player') !== -1 || u.indexOf('get_watch') !== -1; }
      // (a) inline ytInitialPlayerResponse global (fresh watch-page paint)
      try {
        var _v;
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true,
          get: function(){ return _v; },
          set: function(x){ _v = strip(x); }
        });
      } catch(e){}
      // (b) fetch() responses — /youtubei/v1/player on SPA navigation
      try {
        var _f = window.fetch;
        window.fetch = function(){
          return _f.apply(this, arguments).then(function(resp){
            try {
              if(!resp || !wanted(resp.url)) return resp;
              return resp.clone().text().then(function(t){
                var s = scrub(t);
                if(s === t) return resp;
                return new Response(s, { status: resp.status, statusText: resp.statusText, headers: resp.headers });
              }).catch(function(){ return resp; });
            } catch(e){ return resp; }
          });
        };
      } catch(e){}
      // (c) XMLHttpRequest responses — shadow responseText/response with the scrubbed body,
      // registered in open() so it runs before the page's own readystatechange handler reads it.
      try {
        var _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url){
          try { this.__mtUrl = url; } catch(e){}
          try {
            this.addEventListener('readystatechange', function(){
              if(this.readyState !== 4 || !wanted(this.__mtUrl)) return;
              try {
                var t = this.responseText, s = scrub(t);
                if(s !== t){
                  Object.defineProperty(this, 'responseText', { value: s, configurable: true });
                  Object.defineProperty(this, 'response',     { value: s, configurable: true });
                }
              } catch(e){}
            });
          } catch(e){}
          return _open.apply(this, arguments);
        };
      } catch(e){}
    })();
    """

    /// One host-driven ad-skip tick (see Coordinator.startAdSkip). Runs ~2x/sec; a near-no-op
    /// unless the player is mid-ad. cancelPlayback() dismisses the ad + resumes content; muting and
    /// the Skip-button click are belt-and-suspenders. Re-checks the live ad-block flag so the
    /// toggle governs it. NEVER touches the player response → forward seeking is unaffected.
    ///
    /// CRITICAL: muting is REVERSIBLE. We stash the pre-ad muted state in window.__mtAdMute and
    /// restore it the instant `.ad-showing` clears. Without this, if cancelPlayback() fails to kill
    /// the ad (notably when the app is inactive — a background window stole focus — so host-eval
    /// user-activation is weak), the ad plays out muted and content resumes on the SAME <video>
    /// element with `.muted` still latched behind YouTube's UI → video stuck permanently silent
    /// (the volume icon shows unmuted; the slider never clears element-level muted). [[the-ad-mute-latch-bug]]
    static let adSkipTick = """
    (function(){
      try {
        var v = document.querySelector('video');
        var mp = document.getElementById('movie_player');
        var adShowing = !!(mp && mp.classList && mp.classList.contains('ad-showing'));
        if(!(window.__MT && window.__MT.adBlock)){
          // Ad-block turned off mid-ad: undo any mute WE applied, then stand down.
          if(window.__mtAdMute){ if(v) v.muted = window.__mtAdMute.was; window.__mtAdMute = null;
            if(window.__MT && window.__MT.debug){ try { window.webkit.messageHandlers.minitube.postMessage({action:'admute', on:false, why:'adblock-off'}); } catch(e){} } }
          return;
        }
        if(!adShowing){
          // Not (or no longer) an ad → restore the pre-ad muted state exactly once.
          if(window.__mtAdMute){ if(v) v.muted = window.__mtAdMute.was; window.__mtAdMute = null;
            if(window.__MT.debug){ try { window.webkit.messageHandlers.minitube.postMessage({action:'admute', on:false, why:'ad-cleared'}); } catch(e){} } }
          return;
        }
        // Mid-ad: remember the real muted state ONCE, then mute + try to dismiss.
        if(!window.__mtAdMute){ window.__mtAdMute = { was: v ? v.muted : false };
          if(window.__MT.debug){ try { window.webkit.messageHandlers.minitube.postMessage({action:'admute', on:true, was: window.__mtAdMute.was}); } catch(e){} } }
        if(v) v.muted = true;
        if(mp && typeof mp.cancelPlayback === 'function'){ try { mp.cancelPlayback(); } catch(e){} }
        try { mp && mp.playVideo && mp.playVideo(); } catch(e){}
        var sk = document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-container button');
        if(sk){ try { sk.click(); } catch(e){} }
      } catch(e){}
    })();
    """

    /// Host-driven auto-fullscreen tick. When __MT.autoFullscreen is on, enter YouTube's real
    /// fullscreen ONCE per video as soon as content is genuinely playing (not an ad, not paused).
    /// Clicking .ytp-fullscreen-button from a host evaluateJavaScript call satisfies the Fullscreen
    /// API's user-activation requirement (verified) — an in-page timer's click would be ignored,
    /// which is why this lives here. Tracked per videoId so exiting fullscreen isn't fought, and
    /// a new video re-triggers ("when they start and are clicked on").
    static let autoFullscreenTick = """
    (function(){
      try {
        if(!(window.__MT && window.__MT.autoFullscreen)) return;
        var mp = document.getElementById('movie_player'); var v = document.querySelector('video');
        if(!mp || !v) return;
        var id; try { id = new URLSearchParams(location.search).get('v'); } catch(e){ return; }
        if(!id || window.__mtFsVid === id) return;                 // handled this video already
        if(document.fullscreenElement || document.webkitFullscreenElement){ window.__mtFsVid = id; return; }
        if(mp.classList.contains('ad-showing')) return;            // wait past ads
        if(v.paused || (v.currentTime || 0) < 1.5) return;         // wait until content is settled
        // Click EXACTLY once per video and mark it done immediately — NEVER retry. Retrying
        // thrashes: the fullscreen button toggles, so repeated clicks flip in/out of fullscreen
        // and break playback. One click when content is settled is enough; a miss just means
        // no fullscreen (harmless), and a new video re-arms via the videoId guard.
        window.__mtFsVid = id;
        var b = document.querySelector('.ytp-fullscreen-button');
        if(b){ try { b.click(); } catch(e){} }
      } catch(e){}
    })();
    """

    /// SponsorBlock skip (community segments from sponsor.ajay.app — the live upstream source,
    /// so this "uses the updates" with no app release). Categories are DATA-DRIVEN from
    /// __MT.sbCategories (the user's Settings). Ad handling lives entirely in adBlockJS.
    static let engineJS = """
    (function(){
      if(!window.__MT) window.__MT = { sponsorBlock:true };
      var CRE = /^[a-z_]{3,32}$/;
      var CAT_FALLBACK = ['sponsor','selfpromo','interaction','intro','outro','preview','music_offtopic'];
      var segs = [], lastKey = null;
      function vid(){ try { return new URLSearchParams(location.search).get('v'); } catch(e){ return null; } }
      function cats(){ var c = window.__MT.sbCategories; c = (c && c.length !== undefined) ? c : CAT_FALLBACK;
        return c.filter(function(x){ return typeof x==='string' && CRE.test(x); }); }
      function loadSegs(id, c){
        fetch('https://sponsor.ajay.app/api/skipSegments?videoID='+id+'&categories='+encodeURIComponent(JSON.stringify(c)))
          .then(function(r){ return r.ok ? r.json() : []; })
          .then(function(d){ segs = (d||[]).filter(function(s){ return s.segment && s.segment.length>=2; }); })
          .catch(function(){});
      }
      // Re-fetch when the video, the on/off state, OR the category set changes — so a mid-video
      // category toggle (flags live-push) takes effect within ~1s, and enabling SponsorBlock
      // mid-video actually fetches (it previously waited for the next video). Never when the
      // native extension handles it (nativeSB).
      setInterval(function(){
        var id = vid(); if(!id) return;
        var c = cats();
        var on = window.__MT.sponsorBlock && !window.__MT.nativeSB;
        var key = id + '|' + (on ? 1 : 0) + '|' + c.join(',');
        if(key !== lastKey){ lastKey = key; segs = []; if(on && c.length) loadSegs(id, c); }
      }, 800);

      setInterval(function(){
        var v = document.querySelector('video.html5-main-video') || document.querySelector('video');
        if(v && window.__MT.sponsorBlock && !window.__MT.nativeSB && segs.length){
          var t = v.currentTime;
          for(var i=0;i<segs.length;i++){ var s=segs[i]; if(s.actionType && s.actionType!=='skip') continue; if(t>=s.segment[0] && t<s.segment[1]-0.3){ v.currentTime=s.segment[1]; break; } }
        }
      }, 200);
    })();
    """

    /// Picture quality: (1) force the highest available source resolution, and
    /// (2) an "Enhance" GPU detail-sharpen (unsharp-mask via SVG feConvolveMatrix +
    /// a touch of contrast/saturation) applied to just the <video> element. WebKit
    /// composites CSS/SVG filters on the GPU (Metal) with zero pixel readback, so
    /// this works on YouTube's DRM/MSE stream where frame-capture upscalers can't.
    /// The swatch (off/subtle/sharper) picks the FAMILY; the actual strength scales
    /// with the playing resolution — most on 480p/720p, none on 4K.
    static let enhanceJS = """
    (function(){
      if(!window.__MT) window.__MT = {};
      if(window.__MT.maxResolution === undefined) window.__MT.maxResolution = true;
      if(window.__MT.enhance === undefined) window.__MT.enhance = 'subtle';
      if(window.__MT.playbackSpeed === undefined) window.__MT.playbackSpeed = 1;

      function post(m){ try { window.webkit.messageHandlers.minitube.postMessage(m); } catch(e){} }

      // One-time ground-truth probe: can THIS WebView actually decode HDR (AV1 pref'd,
      // then VP9.2), and is the display HDR-capable? This is the real gate behind the
      // Chrome UA — it tells us whether HDR can appear at all, independent of the video.
      var __mtProbed = false;
      function probeHDR(){
        if(__mtProbed) return; __mtProbed = true;
        var display = false;
        try { display = window.matchMedia('(dynamic-range: high)').matches; } catch(e){}
        var mc = navigator.mediaCapabilities;
        if(!mc || !mc.decodingInfo){ post({action:'hdrcap', av1:false, vp9:false, display:display}); return; }
        var hdrVid = function(codecs, mime){ return { type:'media-source', video:{
          contentType: mime + '; codecs="' + codecs + '"', width:3840, height:2160,
          bitrate:20000000, framerate:60, transferFunction:'pq', colorGamut:'rec2020' } }; };
        var av1 = hdrVid('av01.0.13M.10.0.110.09.16.09.0', 'video/mp4');   // level 5.1 for 4K60
        var vp9 = hdrVid('vp09.02.51.10.01.09.16.09.00', 'video/webm');   // level 5.1 for 4K60
        Promise.all([
          mc.decodingInfo(av1).catch(function(){ return { supported:false }; }),
          mc.decodingInfo(vp9).catch(function(){ return { supported:false }; })
        ]).then(function(r){
          post({action:'hdrcap', av1:!!(r[0]&&r[0].supported), vp9:!!(r[1]&&r[1].supported), display:display});
        });
      }

      // One dynamic sharpen filter whose kernel we retune per-frame-size; CSS vars
      // carry the matching tone tweak. Normalized cross kernel (sums to 1) → no
      // brightness shift and amounts stay below the ringing/halo threshold.
      function ensureAssets(){
        if(!document.getElementById('mt-filters') && document.body){
          var wrap = document.createElement('div');
          wrap.innerHTML =
            '<svg id="mt-filters" aria-hidden="true" width="0" height="0" style="position:absolute;width:0;height:0;overflow:hidden;pointer-events:none"><defs>'
            + '<filter id="mt-sharp" x="0" y="0" width="100%" height="100%" color-interpolation-filters="sRGB">'
            + '<feConvolveMatrix id="mt-sharp-k" order="3" preserveAlpha="true" edgeMode="duplicate" divisor="1" bias="0" kernelMatrix="0 0 0  0 1 0  0 0 0"/></filter>'
            + '</defs></svg>';
          document.body.appendChild(wrap.firstChild);
        }
        if(!document.getElementById('mt-enh-css')){
          var st = document.createElement('style'); st.id = 'mt-enh-css';
          st.textContent =
            // Layer-promotion (translateZ/will-change) is applied ONLY together with the filter,
            // never unconditionally: forcing a compositing layer on the bare 4K video makes WebKit
            // (macOS 26) decode it but composite BLACK. With no filter active the video keeps its
            // default rendering path and paints normally.
            '#movie_player.mt-enh video.html5-main-video{ filter:url(#mt-sharp) contrast(var(--mt-c,1)) saturate(var(--mt-s,1)); will-change:filter; transform:translateZ(0); backface-visibility:hidden; }';
          (document.head||document.documentElement).appendChild(st);
        }
      }

      // Resolution-adaptive sharpen amount. Lower source res (upscaled more on the
      // display) gets more sharpening; 4K+ gets none. 'sharper' is a stronger curve.
      function amountFor(fam, h){
        if(fam==='off' || !h) return 0;
        var base;
        if(h <= 360) base = 0.50;
        else if(h <= 480) base = 0.40;
        else if(h <= 720) base = 0.30;
        else if(h <= 1080) base = 0.18;
        else if(h <= 1440) base = 0.10;
        else base = 0.0;                     // >=2160 (4K/8K): off
        return fam==='sharper' ? Math.min(base * 1.8, 0.9) : base;
      }

      // Is the CURRENT video genuinely HDR? Most reliable signal is the player's
      // quality metadata: HDR renditions are labelled like "2160p60 HDR".
      function isHDR(){
        var p = document.getElementById('movie_player');
        try {
          if(p && typeof p.getAvailableQualityData === 'function'){
            var d = p.getAvailableQualityData() || [];
            if(d.some(function(q){ return q && q.isPlayable !== false && /hdr/i.test(q.qualityLabel || q.quality || ''); })) return true;
          }
        } catch(e){}
        // Fallback: the quality menu labels, if the settings menu has been built.
        try {
          var ls = document.querySelectorAll('.ytp-quality-menu .ytp-menuitem-label, .ytp-menuitem-label');
          for(var i=0;i<ls.length;i++){ if(/\\bHDR\\b/i.test(ls[i].textContent || '')) return true; }
        } catch(e){}
        return false;
      }

      var lastPost = -1;
      function applyEnhance(){
        var mp = document.getElementById('movie_player'); if(!mp) return;
        ensureAssets();
        var v = document.querySelector('video.html5-main-video');
        var h = v ? (v.videoHeight | 0) : 0;
        var fam = window.__MT.enhance || 'off';
        var a = amountFor(fam, h);
        // GPU saver (Visionary running): the convolution filter is the app's
        // biggest GPU cost — shed it entirely. Also drop it while paused: a
        // parked frame doesn't need a live per-frame filter.
        if(window.__MT.gpuSaver) a = 0;
        if(v && v.paused) a = 0;

        if(a > 0){
          var c = (1 + 4 * a).toFixed(3), e = (-a).toFixed(3);
          var k = document.getElementById('mt-sharp-k');
          if(k) k.setAttribute('kernelMatrix', '0 ' + e + ' 0  ' + e + ' ' + c + ' ' + e + '  0 ' + e + ' 0');
          mp.style.setProperty('--mt-c', (1 + a * 0.12).toFixed(3));
          mp.style.setProperty('--mt-s', (1 + a * 0.18).toFixed(3));
          mp.classList.add('mt-enh');
        } else {
          mp.classList.remove('mt-enh');
        }

        // Report resolution + enhance-on + HDR back to the app for the readout.
        var hdr = isHDR();
        var sig = h * 10 + (a > 0 ? 2 : 0) + (hdr ? 1 : 0);
        if(sig !== lastPost){
          lastPost = sig;
          post({action:'enhance', height:h, amount:a, hdr:hdr});
        }
      }

      // Self-healing max-resolution pin. Two things it gets right that the old one-shot pin
      // didn't: (1) it re-pins when the top level RISES — on WebKit a video's 4K/HDR-AV1
      // rendition can populate AFTER the lower ones, so committing once on the first list
      // latched a sub-max level forever; (2) "Max Quality" is the user's EXPLICIT demand for
      // the best rendition, so it targets the ABSOLUTE max (resolution is NOT the Visionary
      // bottleneck — native players do 4K HDR fine alongside Topaz). Re-pinning is rate-limited
      // so a normal ABR ramp doesn't thrash YouTube's buffer controller; once accepted, it stops.
      var __mtQ = { vid:null, target:null, reached:false, lastAt:0, tries:0 };
      function forceMaxQuality(){
        if(!window.__MT.maxResolution) return;
        var p = document.getElementById('movie_player');
        if(!p || typeof p.getAvailableQualityLevels !== 'function') return;
        // Live streams / premieres: never pin — the live edge NEEDS ABR headroom
        // (a pinned live edge stalls hard on any dip; VOD just rebuffers politely).
        try { var v0 = document.querySelector('video.html5-main-video');
              if(v0 && v0.duration === Infinity) return;
              var vd = p.getVideoData ? p.getVideoData() : null;
              if(vd && vd.isLive) return; } catch(e){}
        var levels; try { levels = p.getAvailableQualityLevels(); } catch(e){ return; }
        if(!levels || !levels.length) return;
        var curV = null; try { curV = new URLSearchParams(location.search).get('v'); } catch(e){}
        if(curV !== __mtQ.vid){                             // new video → re-arm
          __mtQ = { vid:curV, target:null, reached:false, lastAt:0, tries:0 };
        }
        var want = levels[0];                               // absolute max — honor the explicit toggle
        var cur = ''; try { cur = p.getPlaybackQuality(); } catch(e){}
        if(cur === want){ __mtQ.target = want; __mtQ.reached = true; return; }  // accepted → stop
        var now = Date.now();
        var rose = (want !== __mtQ.target);                 // list grew to expose a higher rendition
        if(rose) __mtQ.tries = 0;
        // Re-pin on target-rise (the HDR/4K-late-populate fix), else self-heal a bounded few
        // times if the request hasn't been accepted yet (spaced out to avoid buffer thrash).
        if(rose || (!__mtQ.reached && __mtQ.tries < 5 && (now - __mtQ.lastAt) > 3500)){
          try { p.setPlaybackQualityRange(want, want); } catch(e){}
          __mtQ.target = want; __mtQ.lastAt = now; __mtQ.tries++;
        }
      }

      // Autoplay: tell the app when the video genuinely ends (listener re-attached
      // if YouTube swaps the <video> element).
      function hookEnded(){
        var v = document.querySelector('video.html5-main-video');
        if(v && !v.__mtEndHook){
          v.__mtEndHook = true;
          v.addEventListener('ended', function(){ post({action:'ended'}); });
        }
      }

      // Mark-as-watched: once a video has genuinely been WATCHED — ~15s of real forward
      // playback accumulated (seeks/rewinds excluded), or half of a short clip — tell the
      // app once so it logs the view to the signed-in account's YouTube history. tick() runs
      // ~1s apart, so each playing tick contributes ~1s; a seek (delta ≥ 2s) is not counted.
      var __mtSeen = {};   // videoId → { acc, last, done }
      function maybeMarkWatched(){
        var v = document.querySelector('video.html5-main-video'); if(!v || v.paused || v.seeking) return;
        var mp = document.getElementById('movie_player');
        if(mp && mp.classList.contains('ad-showing')) return;   // never count ad playback
        var id; try { id = new URLSearchParams(location.search).get('v'); } catch(e){ return; }
        if(!id) return;
        var s = __mtSeen[id] || (__mtSeen[id] = { acc:0, last:v.currentTime, done:false });
        if(s.done) return;
        var t = v.currentTime, d = t - s.last; s.last = t;
        // Accumulate CONTENT seconds actually played. A normal ~1s tick advances currentTime by
        // ~playbackRate seconds, so scale the seek cutoff by rate (2x/4x playback stays counted)
        // and cap each tick's credit at one rate-step (jitter-proof). Real seeks jump further → dropped.
        var rate = v.playbackRate || 1;
        if(d > 0 && d <= rate * 2) s.acc += Math.min(d, rate);
        var dur = v.duration || 0;
        // ~15s of real play, OR half of any sub-minute clip (so a full view of a short/Short counts).
        if(s.acc >= 15 || (dur > 0 && dur < 60 && s.acc >= Math.min(15, dur * 0.5))){
          s.done = true;
          post({action:'markWatched', videoId:id});
        }
      }

      // Playback speed: keep the player at the app's chosen rate (window.__MT.playbackSpeed).
      // Re-assert whenever the player drifts from it — notably YouTube resets the rate to 1 on
      // every SPA navigation, so this restores it on the next video. All offered rates
      // (1/1.25/1.5/1.75/2) are standard YouTube-supported rates.
      function applyPlaybackRate(){
        var v = document.querySelector('video.html5-main-video'); if(!v) return;
        var want = +window.__MT.playbackSpeed || 1;
        // The <video> element's rate is the reliable truth (movie_player.getPlaybackRate() can
        // lag/report 1 while playback is actually faster). Only act on real drift — the initial
        // set, a changed setting, or YouTube resetting the rate to 1 on SPA navigation.
        if(Math.abs((v.playbackRate || 1) - want) > 0.001){
          var mp = document.getElementById('movie_player');
          if(mp && typeof mp.setPlaybackRate === 'function'){ try { mp.setPlaybackRate(want); } catch(e){} }
          try { v.playbackRate = want; } catch(e){}
        }
      }

      function tick(){ forceMaxQuality(); applyPlaybackRate(); applyEnhance(); hookEnded(); maybeMarkWatched(); }
      setInterval(tick, 1000);
      // YouTube is an SPA — quality + player element reset on each navigation.
      document.addEventListener('yt-navigate-finish', tick, true);
      setTimeout(tick, 800); setTimeout(tick, 2500);
      setTimeout(probeHDR, 1500);   // report HDR decode capability once

      // Buffer diagnostics → app debug log — DEBUG SESSIONS ONLY (touch /tmp/mt-debug
      // before launch). A normal run posts nothing and writes nothing every 3s.
      setInterval(function(){
        if(!window.__MT.debug) return;
        var v = document.querySelector('video.html5-main-video'); if(!v) return;
        var end = 0; try { if(v.buffered && v.buffered.length) end = v.buffered.end(v.buffered.length - 1); } catch(e){}
        var p = document.getElementById('movie_player');
        var q = ''; try { q = (p && p.getPlaybackQuality) ? p.getPlaybackQuality() : ''; } catch(e){}
        post({action:'buf', t: Math.round(v.currentTime), end: Math.round(end), rs: v.readyState, paused: v.paused, q: q});
        // Rendering diagnostic: WHY the player can show black while the media decodes.
        try {
          var cs = getComputedStyle(v); var r = v.getBoundingClientRect();
          var cx = Math.round(r.left + r.width/2), cy = Math.round(r.top + r.height/2);
          var hit = document.elementFromPoint(cx, cy);
          var pcs = p ? getComputedStyle(p) : null;
          post({action:'render',
            fs: (document.fullscreenElement || document.webkitFullscreenElement) ? 1 : 0,
            vrect: Math.round(r.left)+','+Math.round(r.top)+' '+Math.round(r.width)+'x'+Math.round(r.height),
            vw: v.videoWidth+'x'+v.videoHeight,
            filter: cs.filter, opacity: cs.opacity, vis: cs.visibility, disp: cs.display,
            transform: cs.transform, mixblend: cs.mixBlendMode,
            pbg: pcs? pcs.backgroundColor : '', ppos: pcs? pcs.position : '',
            inner: window.innerWidth+'x'+window.innerHeight,
            hit: hit ? (hit.tagName+'.'+String(hit.className||'').slice(0,36)) : 'none'});
        } catch(e){ post({action:'render', err: String(e)}); }
      }, 3000);
    })();
    """
}
