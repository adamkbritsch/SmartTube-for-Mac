import SwiftUI
import AppKit
import ImageIO

// Hover-to-preview, like youtube.com — a lightweight CGImage animation (no video, no page load).
// Two frame sources, picked per video, both animated the same way:
//   • Animated WebP (`an_webp`) — the smooth ~24-frame clip YouTube ships in the feed data
//     (search / channels / watch recommendations). Hard-cut playback (it's a mini video).
//   • Sampled frame thumbnails — mqdefault + mq1/mq2/mq3.jpg (poster + ~25/50/75%), the fallback
//     for the home & subscriptions feeds which carry no an_webp URL. Cross-faded (4 frames).

struct PreviewClip { let frames: [CGImage]; let delays: [Double]; let crossfade: Bool }

enum PreviewCache {
    private final class Box { let clip: PreviewClip; init(_ c: PreviewClip) { clip = c } }
    private static let cache = NSCache<NSString, Box>()

    /// The right clip for a video: the smooth WebP when the feed shipped one, else the light
    /// sampled-frame cycle (which works for every video, no API/signature needed).
    static func load(previewUrl: String?, videoId: String) async -> PreviewClip? {
        if let url = previewUrl, !url.isEmpty, let clip = await loadWebP(url) { return clip }
        return await loadFrames(videoId)
    }

    // MARK: Animated WebP

    private static func loadWebP(_ url: String) async -> PreviewClip? {
        let key = url as NSString
        if let hit = cache.object(forKey: key) { return hit.clip }
        guard let u = URL(string: url),
              let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 1 else { return nil }   // must be animated (a single frame is just a thumbnail)
        var frames: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<n {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(img)
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let d = (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                 ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double) ?? 0.1
            delays.append(d > 0.01 ? d : 0.1)
        }
        guard frames.count > 1 else { return nil }
        let clip = PreviewClip(frames: frames, delays: delays, crossfade: false)
        cache.setObject(Box(clip), forKey: key)
        return clip
    }

    // MARK: Sampled frames (mqdefault + mq1/mq2/mq3) — light, universal, unsigned

    private static func loadFrames(_ videoId: String) async -> PreviewClip? {
        let key = "frames:\(videoId)" as NSString
        if let hit = cache.object(forKey: key) { return hit.clip }
        let names = ["mqdefault", "mq1", "mq2", "mq3"]   // poster + ~25/50/75%
        let fetched: [(Int, CGImage)] = await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, name) in names.enumerated() {
                group.addTask {
                    guard let u = URL(string: "https://i.ytimg.com/vi/\(videoId)/\(name).jpg"),
                          let (data, resp) = try? await URLSession.shared.data(from: u),
                          (resp as? HTTPURLResponse)?.statusCode == 200,
                          let src = CGImageSourceCreateWithData(data as CFData, nil),
                          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return (i, nil) }
                    return (i, img)
                }
            }
            var out: [(Int, CGImage)] = []
            for await pair in group { if let img = pair.1 { out.append((pair.0, img)) } }
            return out
        }
        let frames = fetched.sorted { $0.0 < $1.0 }.map { $0.1 }
        guard frames.count >= 2 else { return nil }   // too few → card keeps its static thumbnail
        let clip = PreviewClip(frames: frames, delays: Array(repeating: 0.7, count: frames.count), crossfade: true)
        cache.setObject(Box(clip), forKey: key)
        return clip
    }
}

/// Plays a decoded clip by swapping a CALayer's contents on a per-frame timer. WebP clips hard-cut
/// (smooth mini-video); sampled-frame clips cross-fade (4 stills dissolving into each other).
final class WebPLayerView: NSView {
    private var frames: [CGImage] = []
    private var delays: [Double] = []
    private var crossfade = false
    private var i = 0
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // Transparent to the mouse — the card underneath must keep receiving hover, else the
    // preview appearing steals the pointer, fires onHover(false), and flickers off/on forever.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func play(_ clip: PreviewClip) {
        frames = clip.frames; delays = clip.delays; crossfade = clip.crossfade; i = 0
        layer?.contents = frames.first
        schedule()
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    private func schedule() {
        timer?.invalidate()
        guard frames.count > 1 else { return }
        let d = i < delays.count ? max(0.03, delays[i]) : 0.1
        timer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.i = (self.i + 1) % self.frames.count
            if self.crossfade {
                let t = CATransition(); t.type = .fade; t.duration = 0.35
                self.layer?.add(t, forKey: "contents")
            }
            self.layer?.contents = self.frames[self.i]
            self.schedule()
        }
    }
}

struct WebPPreviewView: NSViewRepresentable {
    let clip: PreviewClip
    func makeNSView(context: Context) -> WebPLayerView { let v = WebPLayerView(); v.play(clip); return v }
    func updateNSView(_ v: WebPLayerView, context: Context) {}
    static func dismantleNSView(_ v: WebPLayerView, coordinator: ()) { v.stop() }
}
