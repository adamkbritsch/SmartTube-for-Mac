import WebKit

/// Loads REAL WebExtensions (uBlock Origin Lite + SponsorBlock) into the player's
/// WKWebView via Apple's WKWebExtension API (macOS 15.4+). Extensions are staged to
/// Application Support first: WKWebExtension traps when reading extension files that
/// are sealed inside a code-signed .app bundle, so they must live outside it.
/// If the API/extensions are unavailable, this stays nil and the player falls back to
/// the built-in reactive ad-skip + SponsorBlock engine.
@available(macOS 15.4, *)
@MainActor
final class UBlockLoader {
    static let shared = UBlockLoader()
    private(set) var controller: WKWebExtensionController?
    private(set) var contexts: [String: WKWebExtensionContext] = [:]   // keyed by "uBOL" / "SponsorBlock"
    /// The controller's data store. The player WebView MUST use this same store, otherwise
    /// WKWebExtension silently refuses to inject content scripts into it (which is why
    /// SponsorBlock — and uBO's cosmetic filtering — never actually ran on the page).
    private(set) var dataStore: WKWebsiteDataStore?
    private var loading = false

    /// The extension's own settings/dashboard page URL (from its manifest options_ui).
    func settingsURL(for name: String) -> URL? { contexts[name]?.optionsPageURL }

    /// (Resources bundle name, dev repo path) for each extension to load.
    /// uBlock Origin note: its webRequest network engine is inert under
    /// WKWebExtension (Apple never shipped blocking webRequest), but its
    /// scriptlets + cosmetic filtering DO run — on YouTube those attack the
    /// ad payloads themselves. The app's own engineJS ad-cover is the backstop.
    private static let specs = [
        ("uBO", "extensions/ubo"),
        ("SponsorBlock", "extensions/sponsorblock"),
    ]

    // MARK: Tab/window model (required for content↔background messaging)
    // Without a tab model, WKWebExtension rejects a content script's runtime.sendMessage
    // with "Tab not found" — which silently breaks any extension that coordinates through
    // its background page. uBО's cosmetic filtering doesn't need it, but SponsorBlock does
    // (config, segment fetch, and skip all route through messages). Registering the player
    // WebView as the one tab of one window makes that messaging resolve.
    private let playerTab = PlayerTab()
    private lazy var playerWindow = PlayerWindow(playerTab)
    private let extDelegate = ExtDelegate()   // the ONE controller delegate; vends player + dashboard windows
    private var tabRegistered = false

    /// Register (or re-point) the player WebView as the extension host tab. Call from the
    /// WebPlayer once the WebView exists, before it loads the page.
    func attachPlayer(_ webView: WKWebView) {
        guard let controller else { return }
        playerTab.window = playerWindow
        playerTab.webView = webView
        if !tabRegistered {
            tabRegistered = true
            extDelegate.windows.insert(playerWindow, at: 0)
            controller.didOpenWindow(playerWindow)
            controller.didFocusWindow(playerWindow)
            controller.didOpenTab(playerTab)
            UBlockLoader.log("player tab registered — content↔background messaging enabled")
        }
    }

    /// ExtensionSettings registers/unregisters its dashboard host window here so the SINGLE
    /// controller delegate vends both the player and the open dashboard — instead of two
    /// objects fighting over `controller.delegate` (which would nil out the player tab).
    func registerHostWindow(_ w: any WKWebExtensionWindow, tab: any WKWebExtensionTab) {
        guard let controller else { return }
        extDelegate.windows.append(w)
        controller.didOpenWindow(w)
        controller.didFocusWindow(w)
        controller.didOpenTab(tab)
        controller.didSelectTabs([tab])
    }
    func unregisterHostWindow(_ w: any WKWebExtensionWindow, tab: any WKWebExtensionTab) {
        guard let controller else { return }
        controller.didDeselectTabs([tab])
        extDelegate.windows.removeAll { ($0 as AnyObject) === (w as AnyObject) }
        controller.didCloseWindow(w)
        if tabRegistered { controller.didFocusWindow(playerWindow) }   // refocus the player
    }

    func preload() async {
        guard controller == nil, !loading else { return }
        loading = true; defer { loading = false }

        // Non-persistent controller (in-memory, matches the player's cookie-less store). The
        // player WebView is wired to this same `dataStore` — required for content-script injection.
        let cfg = WKWebExtensionController.Configuration.nonPersistent()
        self.dataStore = cfg.defaultWebsiteDataStore
        let controller = WKWebExtensionController(configuration: cfg)
        controller.delegate = extDelegate   // the single, persistent delegate (set once)
        var loadedAny = false
        for dir in UBlockLoader.stagedExtensionDirs() {
            do {
                let ext = try await WKWebExtension(resourceBaseURL: dir)
                let context = WKWebExtensionContext(for: ext)
                // Headless: grant every declared permission + access to all sites.
                for perm in ext.requestedPermissions {
                    context.setPermissionStatus(.grantedExplicitly, for: perm)
                }
                if let all = try? WKWebExtension.MatchPattern(string: "<all_urls>") {
                    context.setPermissionStatus(.grantedExplicitly, for: all)
                }
                try controller.load(context)
                contexts[dir.lastPathComponent] = context
                loadedAny = true
                UBlockLoader.log("loaded \(ext.displayName ?? dir.lastPathComponent) | settings: \(context.optionsPageURL?.absoluteString ?? "nil")")
                // The options/dashboard pages message the BACKGROUND page and hang
                // silently if it never came up — wake it explicitly and surface why
                // it failed if it does (context.errors is the only visibility we get).
                let name = dir.lastPathComponent
                context.loadBackgroundContent { error in
                    Task { @MainActor in
                        if let error { UBlockLoader.log("\(name) background FAILED: \(error)") }
                        else { UBlockLoader.log("\(name) background loaded") }
                        for e in context.errors { UBlockLoader.log("\(name) context error: \(e)") }
                    }
                }
            } catch {
                UBlockLoader.log("FAILED \(dir.lastPathComponent): \(error)")
            }
        }
        if loadedAny { self.controller = controller }
    }

    /// Copy each extension out of the signed bundle (or dev repo) into Application
    /// Support and return those unsealed directories.
    private static func stagedExtensionDirs() -> [URL] {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let stage = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YouTube", isDirectory: true)

        var out: [URL] = []
        for (resName, devPath) in specs {
            var src: URL?
            if let res = Bundle.main.resourceURL {
                let b = res.appendingPathComponent(resName)
                if fm.fileExists(atPath: b.appendingPathComponent("manifest.json").path) { src = b }
            }
            if src == nil {
                let dev = repo.appendingPathComponent(devPath)
                if fm.fileExists(atPath: dev.appendingPathComponent("manifest.json").path) { src = dev }
            }
            guard let src else { continue }

            // Version the stage: re-copy whenever the BUNDLED extension changes,
            // otherwise the user runs the first-ever staged copy forever (frozen
            // ad-block rules across every app update).
            let dst = stage.appendingPathComponent(resName, isDirectory: true)
            let marker = dst.appendingPathComponent(".stage-version")
            let srcManifest = src.appendingPathComponent("manifest.json")
            let attrs = try? fm.attributesOfItem(atPath: srcManifest.path)
            let version = "\((attrs?[.size] as? Int) ?? 0)-\(((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
            let staged = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            if !fm.fileExists(atPath: dst.appendingPathComponent("manifest.json").path) || staged != version {
                try? fm.removeItem(at: dst)
                try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
                try? fm.copyItem(at: src, to: dst)
                try? version.write(to: marker, atomically: true, encoding: .utf8)
            }
            out.append(fm.fileExists(atPath: dst.appendingPathComponent("manifest.json").path) ? dst : src)
        }
        return out
    }

    /// Mirror load results to the debug log (only in flagged sessions) + stdout.
    private static func log(_ msg: String) {
        print("[ext] \(msg)")
        MTDebug.log("[ext] \(msg)")
    }
}

// MARK: - Minimal WKWebExtension tab/window/delegate
// Just enough of the model for the controller to route content-script messages to the
// background page (so `runtime.sendMessage` resolves instead of failing "Tab not found").
// The app has a single player WebView at a time = one tab in one logical window.

@available(macOS 15.4, *)
final class PlayerTab: NSObject, WKWebExtensionTab {
    weak var webView: WKWebView?
    weak var window: (any WKWebExtensionWindow)?
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { window }
    func url(for context: WKWebExtensionContext) -> URL? { webView?.url }
    func title(for context: WKWebExtensionContext) -> String? { webView?.title }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(webView?.isLoading ?? true) }
}

@available(macOS 15.4, *)
final class PlayerWindow: NSObject, WKWebExtensionWindow {
    let tab: PlayerTab
    init(_ tab: PlayerTab) { self.tab = tab }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [tab] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}

@available(macOS 15.4, *)
final class ExtDelegate: NSObject, WKWebExtensionControllerDelegate {
    /// Player window first, then any open dashboard windows. `.last` is treated as focused
    /// (a dashboard when open, else the player), which is what `tabs.query({currentWindow})` wants.
    var windows: [any WKWebExtensionWindow] = []
    func webExtensionController(_ c: WKWebExtensionController, openWindowsFor ctx: WKWebExtensionContext) -> [any WKWebExtensionWindow] { windows }
    func webExtensionController(_ c: WKWebExtensionController, focusedWindowFor ctx: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { windows.last }
}
