import SwiftUI
import WebKit

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
    var onFullscreen: () -> Void = {}
    var onEnhanceInfo: (Int, Double, Bool) -> Void = { _, _, _ in }   // (playing height, sharpen amount, isHDR)
    var onEnded: () -> Void = {}                                       // video finished (autoplay hook)
    var onTheater: () -> Void = {}                                     // YouTube's own theater button was clicked
    var onMarkWatched: (String) -> Void = { _ in }                    // watched past threshold → log to YouTube history

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true       // YouTube's own fullscreen button
        config.websiteDataStore = .player
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

        // Attach the real uBlock Origin Lite extension (macOS 15.4+) if it loaded.
        if #available(macOS 15.4, *), let controller = UBlockLoader.shared.controller {
            config.webExtensionController = controller
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.latestFlags = flagsJS
        // Desktop-Chrome-on-macOS UA — the field-proven WebKit spoof: removes YouTube's
        // Safari-only AVC/1080p downgrade (so HDR appears) AND streams normally. A Firefox
        // UA on WebKit served a broken path that hard-capped the forward buffer at ~60s;
        // Chrome is the matched/expected combo. UA has NO effect on ads (verified 4×).
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        context.coordinator.load(videoId, into: webView)
        return webView
    }

    /// The window.__MT flag object the injected loops read. Includes nativeSB so the JS
    /// SponsorBlock stands down when the real SponsorBlock extension is loaded (no double-skip).
    private var flagsJS: String {
        var nativeSB = false
        if #available(macOS 15.4, *) { nativeSB = UBlockLoader.shared.contexts["SponsorBlock"] != nil }
        return "window.__MT={adBlock:\(adBlock),sponsorBlock:\(sponsorBlock),maxResolution:\(maxResolution),enhance:'\(enhance)',nativeSB:\(nativeSB),gpuSaver:\(gpuSaver),debug:\(MTDebug.enabled)};"
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
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
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.pauseAllMediaPlayback(completionHandler: nil)
        nsView.loadHTMLString("", baseURL: nil)
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

        init(onFullscreen: @escaping () -> Void, onEnhanceInfo: @escaping (Int, Double, Bool) -> Void, onEnded: @escaping () -> Void, onTheater: @escaping () -> Void, onMarkWatched: @escaping (String) -> Void, adBlock: Bool, sponsorBlock: Bool) {
            self.onFullscreen = onFullscreen; self.onEnhanceInfo = onEnhanceInfo; self.onEnded = onEnded; self.onTheater = onTheater; self.onMarkWatched = onMarkWatched
            self.adBlock = adBlock; self.sponsorBlock = sponsorBlock
        }

        func load(_ videoId: String, into webView: WKWebView) {
            guard loaded != videoId,
                  let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return }
            loaded = videoId
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }

        // Flags now ride in as the FIRST documentStart user script (rebuilt on every
        // settings change), so each navigation starts with the real values — no
        // post-load re-push needed, and no defaults flash before it lands.

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
            case "adprune":
                let surface = (body["surface"] as? String) ?? "?"
                let hadAds = (body["hadAds"] as? Bool) ?? false
                Coordinator.debugLog("adprune surface=\(surface) hadAds=\(hadAds) → \(hadAds ? "PRUNED ad payload" : "clean (no ads present)")")
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

    /// uBlock Origin's YouTube ad-blocking technique (json-prune), run as the SOLE
    /// ad controller. YouTube schedules ads from `adPlacements`/`playerAds`/`adSlots`
    /// in the player response; uBO deletes those fields on every surface the player
    /// reads them — the inline `ytInitialPlayerResponse` global, `fetch()` /player
    /// responses (SPA nav), and `JSON.parse` (XHR). With the ad payload gone, NO ad
    /// is ever loaded or played — nothing to cover or skip. These are uBO's exact
    /// rules (quick-fixes.txt: json-prune of playerResponse.adPlacements/playerAds/
    /// adSlots + adPlacements/playerAds/adSlots). Injected FIRST at documentStart so
    /// it hooks the surfaces before YouTube's player code runs. Gated on __MT.adBlock.
    static let adBlockJS = """
    (function(){
      if(!window.__MT) window.__MT = { adBlock:true };
      if(window.__mtAdPrune) return; window.__mtAdPrune = true;
      var hits = 0;
      function report(surface, hadAds){
        if(!window.__MT.debug) return;
        try { window.webkit.messageHandlers.minitube.postMessage({action:'adprune', surface:surface, hadAds:hadAds, n:++hits}); } catch(e){}
      }
      function prune(o){
        try {
          if(!window.__MT.adBlock || !o || typeof o !== 'object') return o;
          if(Array.isArray(o)){ for(var i=0;i<o.length;i++) prune(o[i]); return o; }
          if('adPlacements' in o){ delete o.adPlacements; }
          if('playerAds' in o){ delete o.playerAds; }
          if('adSlots' in o){ delete o.adSlots; }
          if(o.playerResponse && typeof o.playerResponse === 'object') prune(o.playerResponse);
        } catch(e){}
        return o;
      }
      // Is this the player response (or a wrapper of it)? Used only for debug reporting.
      function playerLike(o){
        return o && typeof o === 'object' &&
               (o.streamingData || o.videoDetails || o.adPlacements || o.playerAds ||
                (o.playerResponse && typeof o.playerResponse === 'object'));
      }
      function hadAds(o){
        if(!o || typeof o !== 'object') return false;
        return !!(o.adPlacements || o.playerAds || o.adSlots ||
                 (o.playerResponse && (o.playerResponse.adPlacements || o.playerResponse.playerAds || o.playerResponse.adSlots)));
      }
      // (a) inline ytInitialPlayerResponse global (initial watch-page paint)
      try {
        var _v;
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true,
          get: function(){ return _v; },
          set: function(x){ if(playerLike(x)) report('ytInitialPlayerResponse', hadAds(x)); _v = prune(x); }
        });
      } catch(e){}
      // (b) fetch() responses — /youtubei/v1/player on SPA navigation
      try {
        var _rj = Response.prototype.json;
        Response.prototype.json = function(){
          var res = this;
          return _rj.call(res).then(function(data){
            try { var u = res.url || '';
              if(u.indexOf('/player') !== -1 || u.indexOf('/youtubei/') !== -1 ||
                 (data && (data.adPlacements || data.playerAds || data.adSlots))){
                if(playerLike(data)) report('fetch:'+(u.indexOf('/player')!==-1?'player':'youtubei'), hadAds(data));
                prune(data);
              }
            } catch(e){}
            return data;
          });
        };
      } catch(e){}
      // (c) JSON.parse — XHR responseText and any other parse path
      try {
        var _p = JSON.parse;
        JSON.parse = function(){ var r = _p.apply(this, arguments);
          try { if(r && typeof r === 'object') prune(r); } catch(e){} return r; };
      } catch(e){}
    })();
    """

    /// SponsorBlock skip (community segments). Ad handling now lives entirely in
    /// adBlockJS (uBlock Origin's json-prune) — this no longer touches ads.
    static let engineJS = """
    (function(){
      if(!window.__MT) window.__MT = { sponsorBlock:true };
      var segs = [], lastId = null;
      function vid(){ try { return new URLSearchParams(location.search).get('v'); } catch(e){ return null; } }
      function loadSegs(){
        var id = vid(); if(!id) return;
        fetch('https://sponsor.ajay.app/api/skipSegments?videoID='+id+'&categories=%5B%22sponsor%22%2C%22selfpromo%22%2C%22interaction%22%2C%22intro%22%2C%22outro%22%2C%22preview%22%2C%22music_offtopic%22%5D')
          .then(function(r){ return r.ok ? r.json() : []; })
          .then(function(d){ segs = (d||[]).filter(function(s){ return s.segment && s.segment.length>=2; }); })
          .catch(function(){});
      }
      // Fetch segments only when the JS skipper is actually the one skipping —
      // never when SponsorBlock is off or the native extension handles it.
      setInterval(function(){ var id=vid(); if(id && id!==lastId){ lastId=id; segs=[];
        if(window.__MT.sponsorBlock && !window.__MT.nativeSB) loadSegs(); } }, 800);

      setInterval(function(){
        var v = document.querySelector('video.html5-main-video') || document.querySelector('video');
        // Skip the JS SponsorBlock when the REAL SponsorBlock extension is loaded (nativeSB) —
        // both seeking near the same boundary caused double-skip jitter. Keep as fallback otherwise.
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
            'video.html5-main-video{ will-change:filter; transform:translateZ(0); backface-visibility:hidden; }'
            + '#movie_player.mt-enh video.html5-main-video{ filter:url(#mt-sharp) contrast(var(--mt-c,1)) saturate(var(--mt-s,1)); }';
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
      // the best rendition, so it targets the ABSOLUTE max even while the GPU saver is active.
      // AV1 4K/HDR decode runs on the hardware media engine, not the Metal cores Visionary
      // needs, so it barely competes; the saver still sheds the per-frame Enhance convolution
      // (the app's real GPU cost) in applyEnhance. Re-pinning is rate-limited so a normal ABR
      // ramp doesn't thrash YouTube's buffer controller (→ 4K stutter); once the request is
      // accepted, it stops.
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

      function tick(){ forceMaxQuality(); applyEnhance(); hookEnded(); maybeMarkWatched(); }
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
      }, 3000);
    })();
    """
}
