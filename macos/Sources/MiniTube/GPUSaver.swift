import AppKit

/// Watches for Visionary (the Topaz upscaler — renamed app, bundle id unchanged)
/// and flips `active` while it runs. The player sheds its optional GPU load in
/// that window: the Enhance convolution filter goes off and the quality pin caps
/// at the player's actual backing resolution instead of absolute max. The user's
/// saved settings are untouched — everything restores the moment Visionary quits.
@MainActor
final class GPUSaver: ObservableObject {
    static let shared = GPUSaver()
    @Published private(set) var active = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        check()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.check() }
            })
        }
    }

    private func check() {
        let heavy = NSWorkspace.shared.runningApplications.contains { app in
            let bid = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return bid.contains("topaz") || name == "visionary" || name.contains("topaz video")
        }
        if heavy != active {
            active = heavy
            print("[YouTube] GPU saver \(heavy ? "ON" : "off") (Visionary \(heavy ? "running" : "gone"))")
        }
    }
}
