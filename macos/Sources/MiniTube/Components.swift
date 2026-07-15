import SwiftUI

// MARK: - Cached remote images (A11)

/// Process-wide decoded-image cache. AsyncImage keeps no decoded cache, so every
/// scroll-back / chip switch re-fetched and re-decoded thumbnails.
@MainActor
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400          // thumbnails + avatars; a few hundred is plenty
        return c
    }()
    static func image(for url: String) -> NSImage? { cache.object(forKey: url as NSString) }
    static func store(_ image: NSImage, for url: String) { cache.setObject(image, forKey: url as NSString) }
}

/// Drop-in cached replacement for the AsyncImage pattern used across the app:
/// remote image scaled to fill, with a custom placeholder while loading/failed.
struct CachedImage<Placeholder: View>: View {
    let url: String
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if let hit = ImageCache.image(for: url) { image = hit; return }
            image = nil
            guard let u = URL(string: url), !url.isEmpty else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: u),
                  let img = NSImage(data: data) else { return }
            ImageCache.store(img, for: url)
            image = img
        }
    }
}

// MARK: - Avatar (A13)

/// The one channel-avatar renderer: remote picture when available, colored
/// monogram circle otherwise. Replaces five hand-rolled copies.
struct AvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let url, !url.isEmpty {
                CachedImage(url: url) { monogram }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var monogram: some View {
        Circle().fill(channelColor(name).gradient)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundColor(.white)
            )
    }
}

// MARK: - Shared layout + pill styling (A16)

/// Content-area width (window − sidebar − divider), injected once at the root and
/// read by every grid so column counts reflow with the window. Default keeps
/// previews/standalone renders at the 3-column width.
private struct GridContentWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 1100 }
extension EnvironmentValues {
    var gridContentWidth: CGFloat {
        get { self[GridContentWidthKey.self] }
        set { self[GridContentWidthKey.self] = newValue }
    }
}

enum Grid3 {
    /// Video / playlist columns: 3 only at maximized/fullscreen widths, fewer as the
    /// window narrows — capped at 3 (never squished into 4+). Breakpoints on the
    /// content-area width; one-line tunable.
    static func videoColumns(for width: CGFloat) -> [GridItem] {
        let count: Int
        switch width {
        case 1040...: count = 3
        case 600...:  count = 2
        default:      count = 1
        }
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }
    /// Shorts columns: up to 5, scaling down with width (min 2).
    static func shortsColumns(for width: CGFloat) -> [GridItem] {
        let count = min(5, max(2, Int(width / 220)))
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }
}

/// Capsule chip fill/foreground for the active/inactive pattern repeated across
/// enhance segments, rec chips, and feed chips.
struct PillColors {
    let active: Bool
    var fill: AnyShapeStyle { active ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary.opacity(0.1)) }
}
