import Foundation

/// The Plex HTPC keyboard map, as a pure table.
///
/// Steam Input's "Plex HTPC" community layouts don't speak a controller protocol — they emit
/// ordinary keystrokes. So supporting them is exactly the same job as supporting Plex HTPC's
/// keyboard, and this is that map, transcribed from the SHIPPED
/// `Plex HTPC.app/Contents/Resources/inputmaps/keyboard.json` (1.71.1) rather than from Plex's
/// online docs — those describe the PREDECESSOR app, Plex Media Player, and disagree in ways that
/// matter. Two traps worth naming, both of which this table follows the shipped file on:
///   • PageUp is seek FORWARD, PageDown is BACK. The widely-cited plex-media-player repo has these
///     inverted; an independent Steam layout author testing against real HTPC labels PageUp
///     "Seek Forward", which agrees with the shipped file.
///   • `M` is the context MENU. YouTube's own player binds M to mute, so these keys have to be
///     intercepted rather than forwarded to the page, or the menu button would mute the video.
/// Plex has no mute command at all, which is why none appears here.
///
/// Key codes are the HIToolbox virtual codes (`Events.h`), which is what `NSEvent.keyCode` carries
/// and what Steam's emulated keystrokes arrive as.
enum PlexCommand: Equatable {
    case navigate(FocusDirection)   // arrows
    case activate                   // Return / keypad Enter
    case back                       // Escape / Backspace / B
    case home                       // H, or long-press Back
    case menu                       // M, or long-press Return
    case info                       // I
    case playPause                  // Space / P
    case stop                       // X
    case seek(Double)               // PageUp/PageDown, F/R — Plex documents 10s
    case step(Double)               // Home/End — a chapter, or 10 minutes without them
    case volume(Double)             // = / -
    case toggleSubtitles            // S / L
    case toggleWatched              // W
    case cycleTab(Int)              // [ / ]
}

enum PlexKeyMap {
    /// Keys that carry BOTH a short and a long press, so they can only resolve on key-up.
    static let returnKeys: Set<UInt16> = [36, 76]                  // Return, keypad Enter
    static let backKeys: Set<UInt16> = [53, 51, 11]                // Escape, Delete(⌫), B
    static var longPressKeys: Set<UInt16> { returnKeys.union(backKeys) }

    /// Plex's long-press actions: Return holds to the "more actions" menu, Back holds to Home.
    static func longPress(for code: UInt16) -> PlexCommand? {
        if returnKeys.contains(code) { return .menu }
        if backKeys.contains(code) { return .home }
        return nil
    }

    /// The short press / plain keystroke.
    static func command(for code: UInt16) -> PlexCommand? {
        switch code {
        case 126: return .navigate(.up)
        case 125: return .navigate(.down)
        case 123: return .navigate(.left)
        case 124: return .navigate(.right)
        case 36, 76: return .activate
        case 53, 51, 11: return .back                  // Escape / ⌫ / B
        case 4:  return .home                          // H
        case 46: return .menu                          // M
        case 34: return .info                          // I
        case 49, 35: return .playPause                 // Space / P
        case 7:  return .stop                          // X
        case 116, 3:  return .seek(10)                 // PageUp / F
        case 121, 15: return .seek(-10)                // PageDown / R
        case 119: return .step(600)                    // End  — next chapter, else +10 min
        case 115: return .step(-600)                   // Home — prev chapter, else -10 min
        case 24, 69: return .volume(0.05)              // = / + , keypad +
        case 27, 78: return .volume(-0.05)             // - , keypad -
        case 1, 37: return .toggleSubtitles            // S / L
        case 13: return .toggleWatched                 // W
        case 33: return .cycleTab(-1)                  // [
        case 30: return .cycleTab(1)                   // ]

        // Deliberately unbound, having been checked against Plex's map rather than overlooked:
        //   A `cycle_audio`  — YouTube exposes alternate audio tracks only through its settings
        //                      menu, with no stable control to drive.
        //   Z `cycle_aspect_ratio` — no analogue; the player is always the video's own aspect.
        //   E `exit`         — Plex quits the app on a bare keypress. Left unbound on purpose: a
        //                      stray E from a mis-set layout would kill the session with no undo.
        // Keys from the FPS-template-derived layouts (TAB, WASD, digits, C, D, O, J …) are no-ops
        // here because they are no-ops in Plex too — verified against the shipped keyboard.json.
        default: return nil
        }
    }

    /// Commands that only mean something while a video is open. Everything else is safe to run from
    /// any screen, which is what lets a controller drive the feed as well as the player.
    static func needsVideo(_ c: PlexCommand) -> Bool {
        switch c {
        case .playPause, .stop, .seek, .step, .volume, .toggleSubtitles, .toggleWatched: return true
        default: return false
        }
    }
}
