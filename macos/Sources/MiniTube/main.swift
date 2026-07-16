import AppKit
import SwiftUI
import Combine
import Darwin

// Bootstrap a normal windowed app from a plain SwiftPM executable — no Xcode /
// app bundle required. AppKit sets up the app, then hosts a SwiftUI view tree.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var store: Store!
    private let backend = BackendManager()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MTDebug.startSession()    // truncate + open the debug log (only when flagged)
        MTDebug.log("[MediaCaps] AV1 hardware decode / supported=\(MediaCaps.supported) forced=\(MediaCaps.forceUnsupported)")

        // Hardware gate: HDR/4K need an AV1 hardware decoder (M3+); WebKit can't decode
        // YouTube's other high-res codecs (VP9 removed; no AV1 software fallback). On an
        // unsupported Mac, explain why and quit — before spawning the backend or UI.
        // (To relax this to "warn but run" later, replace the terminate with a `return`
        // after the alert and let the normal launch continue.)
        guard MediaCaps.supported else {
            let alert = NSAlert()
            alert.messageText = "This Mac isn’t supported"
            alert.informativeText = MediaCaps.unsupportedMessage
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        backend.startIfNeeded()   // spawn the Vapor server if it isn't already up
        // The in-player WKWebExtension mode is OFF by default (it hangs navigation on macOS 26);
        // only stage/load the extensions when opted back in for a retest (MT_PLAYER_EXT=1).
        if #available(macOS 15.4, *), WebPlayer.playerUsesExtension { Task { await UBlockLoader.shared.preload() } }
        let store = Store()
        self.store = store
        let root = ContentView().environmentObject(store)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SmartTube"
        // Native unified/transparent titlebar so the dark app reads as one seamless surface.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
        window.isOpaque = true
        window.collectionBehavior.insert(.fullScreenPrimary)   // guarantee toggleFullScreen works
        // Traffic lights / titlebar are AppKit-drawn and ignore SwiftUI's colorScheme,
        // so set the window appearance explicitly and keep it synced with the theme —
        // flipping the theme in the Firefox extension even restyles the traffic lights.
        window.appearance = NSAppearance(named: store.settings.theme == "light" ? .aqua : .darkAqua)
        window.center()
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)

        store.$settings
            .map(\.theme)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak window] theme in
                window?.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
            }
            .store(in: &cancellables)

        store.start()
        print("[MiniTube] launched; window visible=\(window.isVisible)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend.stop()   // tear down the backend we spawned
    }

    // Keep running if the window is closed by accident; reopen it from the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }
}

@MainActor
func launch() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
    _ = delegate   // keep the (weakly-referenced) delegate alive for the app's lifetime
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered stdout so logs stream while running
MainActor.assumeIsolated { launch() }
