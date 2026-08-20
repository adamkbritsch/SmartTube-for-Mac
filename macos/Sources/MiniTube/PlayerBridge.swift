import AppKit
import WebKit

/// Host→player command channel for the Plex-HTPC key map.
///
/// The keys can't simply be forwarded to the page: Plex and YouTube disagree on several of them —
/// most sharply `M`, which is Plex's context menu but YouTube's MUTE. So the monitor intercepts the
/// Plex commands and performs the equivalent here, through the same `evaluateJavaScript` channel
/// the ad-skip and auto-fullscreen ticks already use. Arrow seeking is the deliberate exception:
/// YouTube's own ±5s handling is native and correct, so those keys are passed through untouched.
@MainActor
final class PlayerBridge {
    static let shared = PlayerBridge()

    /// Set while a watch page is mounted; nil otherwise, which is how the monitor knows whether a
    /// player command has anywhere to go.
    weak var webView: WKWebView?
    var isActive: Bool { webView != nil }

    private func js(_ source: String) {
        webView?.evaluateJavaScript("(function(){try{\(source)}catch(e){}})()", completionHandler: nil)
    }
    private static let v = "var v=document.querySelector('video.html5-main-video')||document.querySelector('video');"

    /// Plex `seek_forward` / `seek_backward` — documented as 10s.
    func seek(_ delta: Double) {
        js("\(Self.v)if(v){v.currentTime=Math.max(0,Math.min(v.duration||1e9,v.currentTime+(\(delta))));}")
    }
    /// Plex `step_forward` / `step_backward` — next/previous chapter, or 10 minutes without them.
    func step(_ delta: Double) { seek(delta) }

    func playPause() { js("\(Self.v)if(v){v.paused?v.play():v.pause();}") }
    func play()      { js("\(Self.v)if(v&&v.paused){v.play();}") }
    func pause()     { js("\(Self.v)if(v&&!v.paused){v.pause();}") }

    /// Plex has no mute command at all; volume is up/down only.
    func volume(_ delta: Double) {
        js("\(Self.v)if(v){v.volume=Math.max(0,Math.min(1,v.volume+(\(delta))));}")
    }
    /// True while WebKit has borrowed the player for YouTube's element fullscreen: it REPARENTS the
    /// web view into its own WebCoreFullScreenWindow (the same reparenting PlayerContainer works
    /// around). Escape belongs to WebKit in that state — it is how you leave fullscreen — so the
    /// Back key must not swallow it and close the video instead.
    var isElementFullscreen: Bool {
        guard let w = webView?.window else { return false }
        return NSStringFromClass(type(of: w)).contains("FullScreen")
    }

    func toggleSubtitles() { js("var b=document.querySelector('.ytp-subtitles-button');if(b)b.click();")}
    func cycleAudio()      { /* YouTube exposes no audio-track key; deliberately a no-op */ }
    func toggleFullscreen() { js("var b=document.querySelector('.ytp-fullscreen-button');if(b)b.click();") }
}
