import SwiftUI
import AppKit

/// Which region of the app currently owns keyboard focus. Navigation is resolved by index
/// arithmetic within a zone plus explicit zone-to-zone transitions — never by walking the view
/// tree, because the grids and the comment list are lazy and un-materialised rows have no views
/// to walk to.
enum FocusZone: Hashable {
    case header          // header bar controls
    case sidebar         // sidebar rows
    case chips           // feed filter chips
    case grid            // feed / channel / shorts / playlists card grid
    case watchPlayer     // the video itself (keys pass through to YouTube)
    case watchAction     // playerBar + channel row controls
    case comment         // comment rows
    case rec             // up-next rail
    case sheet           // Settings / sign-in sheet rows
    case menu            // card 3-dot menu, popovers
}

struct FocusTarget: Hashable {
    var zone: FocusZone
    var index: Int
    init(_ zone: FocusZone, _ index: Int = 0) { self.zone = zone; self.index = index }
}

enum FocusDirection { case up, down, left, right }

/// Holds what is focused and whether the keyboard is currently driving. `keyboardActive` is the
/// switch that keeps mouse-only use looking exactly as it did before: nothing highlights until an
/// arrow key is pressed, and the first mouse move puts it away again.
@MainActor
final class FocusEngine: ObservableObject {
    static let shared = FocusEngine()

    @Published private(set) var focused: FocusTarget?
    @Published private(set) var keyboardActive = false
    /// Bumped whenever focus moves, so ScrollViewReaders can scroll the target into view.
    @Published private(set) var scrollTick = 0

    /// Live item counts per zone, published by whichever screen is on screen.
    private var counts: [FocusZone: Int] = [:]
    /// The ids behind a zone's indices (video ids, sidebar labels …). Stored as plain DATA rather
    /// than per-row closures so nothing captures a transient SwiftUI view.
    private var ids: [FocusZone: [String]] = [:]
    /// Column count of the current grid, taken from the same helper the layout uses.
    private var columns = 3

    /// Actions registered by individual controls via `.focusAction`. Keyed by target, so a control
    /// keeps its behaviour in one place instead of the root re-implementing every button.
    private var actions: [FocusTarget: () -> Void] = [:]
    func register(_ target: FocusTarget, _ action: @escaping () -> Void) { actions[target] = action }
    func clearActions(_ zone: FocusZone) { actions = actions.filter { $0.key.zone != zone } }

    /// Supplied by the root view: performs the action for a target (open a video, tap a control…).
    var activate: ((FocusTarget) -> Void)?
    /// Supplied by the root view: what Escape should do at the current level.
    var escape: (() -> Void)?

    // MARK: registration

    func setCount(_ zone: FocusZone, _ n: Int) {
        guard counts[zone] != n else { return }
        counts[zone] = n
        // If focus is now past the end (feed refreshed, filter applied), pull it back in range.
        if let f = focused, f.zone == zone, f.index >= n {
            focused = n > 0 ? FocusTarget(zone, n - 1) : nil
        }
    }
    func setColumns(_ n: Int) { columns = max(1, n) }

    /// Publish a zone's ordered ids (and implicitly its count).
    func setItems(_ zone: FocusZone, _ list: [String]) {
        if ids[zone] != list { ids[zone] = list }
        setCount(zone, list.count)
    }
    /// The id behind a focus target, if the zone published one.
    func id(_ target: FocusTarget) -> String? {
        guard let list = ids[target.zone], target.index >= 0, target.index < list.count else { return nil }
        return list[target.index]
    }
    func count(_ zone: FocusZone) -> Int { counts[zone] ?? 0 }

    /// While true the engine ignores arrows entirely and lets them through to whoever has the
    /// keyboard — used on the watch page so YouTube's own ←/→ seek and ↑/↓ volume keep working.
    var suspended = false

    func isFocused(_ target: FocusTarget) -> Bool { keyboardActive && focused == target }

    /// Mouse took over — hide the ring but remember where focus was.
    func mouseTookOver() {
        guard keyboardActive else { return }
        keyboardActive = false
    }

    func focus(_ target: FocusTarget) {
        focused = target
        keyboardActive = true
        scrollTick &+= 1
    }

    // MARK: key handling

    /// Returns true when the key was consumed.
    func handle(direction: FocusDirection) -> Bool {
        guard !suspended else { return false }
        keyboardActive = true
        guard let current = focused else {
            focus(firstTarget())
            return true
        }
        if let next = resolve(from: current, direction) {
            focus(next)
        }
        return true
    }

    func handleActivate() -> Bool {
        guard !suspended, keyboardActive, let f = focused else { return false }
        if let registered = actions[f] { registered() } else { activate?(f) }
        return true
    }

    func handleEscape() -> Bool {
        guard let escape else { return false }
        escape()
        return true
    }

    /// Where focus lands when the keyboard is used for the first time on a screen.
    private func firstTarget() -> FocusTarget {
        if count(.grid) > 0 { return FocusTarget(.grid, 0) }
        if count(.sidebar) > 0 { return FocusTarget(.sidebar, 0) }
        return FocusTarget(.header, 0)
    }

    /// Index arithmetic within a zone, plus the explicit transitions between zones.
    private func resolve(from t: FocusTarget, _ d: FocusDirection) -> FocusTarget? {
        let n = count(t.zone)
        switch t.zone {
        case .grid:
            switch d {
            case .right: return t.index + 1 < n ? FocusTarget(.grid, t.index + 1) : nil
            case .left:
                // Leaving the first column moves to the sidebar rather than wrapping backwards.
                if t.index % columns == 0 { return count(.sidebar) > 0 ? FocusTarget(.sidebar, 0) : nil }
                return FocusTarget(.grid, t.index - 1)
            case .down:
                let next = t.index + columns
                return next < n ? FocusTarget(.grid, next) : nil
            case .up:
                let next = t.index - columns
                if next >= 0 { return FocusTarget(.grid, next) }
                return count(.chips) > 0 ? FocusTarget(.chips, 0) : FocusTarget(.header, 0)
            }
        case .chips:
            switch d {
            case .right: return t.index + 1 < n ? FocusTarget(.chips, t.index + 1) : nil
            case .left:  return t.index > 0 ? FocusTarget(.chips, t.index - 1) : FocusTarget(.sidebar, 0)
            case .down:  return count(.grid) > 0 ? FocusTarget(.grid, 0) : nil
            case .up:    return FocusTarget(.header, 0)
            }
        case .sidebar:
            switch d {
            case .down:  return t.index + 1 < n ? FocusTarget(.sidebar, t.index + 1) : nil
            case .up:    return t.index > 0 ? FocusTarget(.sidebar, t.index - 1) : FocusTarget(.header, 0)
            case .right:
                if count(.chips) > 0 { return FocusTarget(.chips, 0) }
                return count(.grid) > 0 ? FocusTarget(.grid, 0) : nil
            case .left:  return nil
            }
        case .header:
            switch d {
            case .right: return t.index + 1 < n ? FocusTarget(.header, t.index + 1) : nil
            case .left:  return t.index > 0 ? FocusTarget(.header, t.index - 1) : nil
            case .down:
                if count(.chips) > 0 { return FocusTarget(.chips, 0) }
                if count(.grid) > 0 { return FocusTarget(.grid, 0) }
                return count(.sidebar) > 0 ? FocusTarget(.sidebar, 0) : nil
            case .up:    return nil
            }
        default:
            // Watch-page and modal zones are wired in later steps.
            switch d {
            case .down:  return t.index + 1 < n ? FocusTarget(t.zone, t.index + 1) : nil
            case .up:    return t.index > 0 ? FocusTarget(t.zone, t.index - 1) : nil
            default:     return nil
            }
        }
    }
}

// MARK: - The ring

/// Shape of the focus ring, matched to whatever the control already uses.
enum FocusShape { case rect(CGFloat), capsule, circle }

private struct FocusRing: ViewModifier {
    let target: FocusTarget
    let shape: FocusShape
    @ObservedObject private var engine = FocusEngine.shared

    private var on: Bool { engine.isFocused(target) }
    private let accent = Color(red: 0.24, green: 0.65, blue: 1)

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                switch shape {
                case .rect(let r): RoundedRectangle(cornerRadius: r).strokeBorder(accent, lineWidth: 2)
                case .capsule:     Capsule().strokeBorder(accent, lineWidth: 2)
                case .circle:      Circle().strokeBorder(accent, lineWidth: 2)
                }
            }
        }
    }
}

/// Applies focus only when a target exists — conditional rows (a collapsed subscription list, a
/// hidden Back button) simply opt out instead of forcing every call site into an `if let`.
struct OptionalFocus: ViewModifier {
    let target: FocusTarget?
    var shape: FocusShape = .rect(10)
    let action: () -> Void
    func body(content: Content) -> some View {
        if let target {
            content.focusAction(target, shape: shape, action)
        } else {
            content
        }
    }
}

private struct FocusAction: ViewModifier {
    let target: FocusTarget
    let shape: FocusShape
    let action: () -> Void
    func body(content: Content) -> some View {
        content
            .focusRing(target, shape: shape)
            .onAppear { FocusEngine.shared.register(target, action) }
    }
}

extension View {
    /// Draws the focus ring AND registers what Enter should do here, so a control's behaviour
    /// stays with the control.
    func focusAction(_ target: FocusTarget, shape: FocusShape = .rect(10), _ action: @escaping () -> Void) -> some View {
        modifier(FocusAction(target: target, shape: shape, action: action))
    }

    /// Draws the app's existing focused-control treatment (the same accent stroke the focused
    /// search field uses) when this target holds keyboard focus. Renders nothing at all until the
    /// keyboard is actually used, so mouse-only use is visually unchanged. Purely an overlay — no
    /// layout, size or spacing effect.
    func focusRing(_ target: FocusTarget, shape: FocusShape = .rect(12)) -> some View {
        modifier(FocusRing(target: target, shape: shape))
    }
}
