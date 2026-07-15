import SwiftUI

// MARK: - Shimmer

/// Animated left-to-right shimmer sweep for skeleton placeholders.
private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let w = geo.size.width
                    LinearGradient(colors: [.clear, Color.white.opacity(0.4), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(w, 1) * 0.5)
                        .offset(x: -w * 0.75 + phase * w * 1.5)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                .clipped()
            )
            .onAppear {
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    /// Apply to a skeleton placeholder to animate a loading shimmer across it.
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// A single rounded placeholder bar. `w == nil` fills the available width (a full text line).
private struct SkeletonBar: View {
    var w: CGFloat? = nil
    var h: CGFloat = 12
    var corner: CGFloat = 6
    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(Color.primary.opacity(0.08))
            .frame(width: w, height: h)
    }
}

private func skeletonThumb(_ ratio: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 12)
        .fill(Color.primary.opacity(0.08))
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: .infinity)
}

// MARK: - Card skeletons (mirror the real card layouts)

struct SkeletonVideoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            skeletonThumb(16.0 / 9.0)
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(Color.primary.opacity(0.08)).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 7) {
                    SkeletonBar(h: 13)             // title line 1 (full)
                    SkeletonBar(w: 150, h: 13)     // title line 2 (partial)
                    SkeletonBar(w: 110, h: 11)     // channel
                    SkeletonBar(w: 80, h: 10)      // meta
                }
                Spacer(minLength: 0)
            }
        }
        .shimmering()
    }
}

struct SkeletonShortCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            skeletonThumb(9.0 / 16.0)
            SkeletonBar(h: 12)
            SkeletonBar(w: 90, h: 12)
        }
        .shimmering()
    }
}

struct SkeletonPlaylistCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            skeletonThumb(16.0 / 9.0)
            SkeletonBar(h: 13)
            SkeletonBar(w: 120, h: 13)
        }
        .shimmering()
    }
}

struct SkeletonCommentRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(Color.primary.opacity(0.08)).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBar(w: 140, h: 11)     // author
                SkeletonBar(h: 12)             // text line 1
                SkeletonBar(w: 220, h: 12)     // text line 2
            }
            Spacer(minLength: 0)
        }
        .shimmering()
    }
}

// MARK: - Grid skeletons (column configs match the real grids)

struct SkeletonVideoGrid: View {
    @Environment(\.gridContentWidth) private var gridW
    var count = 9
    var body: some View {
        LazyVGrid(columns: Grid3.videoColumns(for: gridW), spacing: 28) {
            ForEach(0..<count, id: \.self) { _ in SkeletonVideoCard() }
        }
        .padding(20)
    }
}

/// One row of video skeletons (for continuous-scroll pagination).
struct SkeletonVideoRow: View {
    @Environment(\.gridContentWidth) private var gridW
    var body: some View {
        LazyVGrid(columns: Grid3.videoColumns(for: gridW), spacing: 28) {
            ForEach(0..<3, id: \.self) { _ in SkeletonVideoCard() }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

struct SkeletonShortGrid: View {
    @Environment(\.gridContentWidth) private var gridW
    var count = 10
    var body: some View {
        LazyVGrid(columns: Grid3.shortsColumns(for: gridW), spacing: 20) {
            ForEach(0..<count, id: \.self) { _ in SkeletonShortCard() }
        }
        .padding(20)
    }
}

struct SkeletonPlaylistGrid: View {
    @Environment(\.gridContentWidth) private var gridW
    var count = 6
    var body: some View {
        LazyVGrid(columns: Grid3.videoColumns(for: gridW), spacing: 24) {
            ForEach(0..<count, id: \.self) { _ in SkeletonPlaylistCard() }
        }
        .padding(20)
    }
}
