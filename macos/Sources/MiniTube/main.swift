import AppKit
import SwiftUI
import Combine
import Darwin
import WebKit

// Bootstrap a normal windowed app from a plain SwiftPM executable — no Xcode /
// app bundle required. AppKit sets up the app, then hosts a SwiftUI view tree.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var store: Store!
    private let backend = BackendManager()
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IONBF, 0)   // unbuffered stdout so diagnostics flush immediately
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
        // Attach the app's own self-rotating session: migrate an existing Firefox login into the
        // persistent store once, push the jar to the backend, start the keepalive.
        Task { @MainActor in await PlayerSession.shared.bootstrap() }
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
        // Belt-and-braces: keep the window object alive across a close so no code path can ever
        // message a freed window (see applicationShouldTerminateAfterLastWindowClosed).
        window.isReleasedWhenClosed = false
        // Needed so the focus ring can hide again the moment the mouse is used:
        // without this the window never delivers .mouseMoved and the monitor below
        // would only ever see key events.
        window.acceptsMouseMovedEvents = true
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
        // Open MAXIMIZED (zoomed), not fullscreen: fill the screen's visibleFrame, which excludes
        // the menu bar and Dock. Fullscreen (.toggleFullScreen) would hide the menu bar and move
        // the app to its own Space — the green button still does that if the user wants it.
        if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
        } else {
            window.center()
        }
        window.contentView = NSHostingView(rootView: root)
        buildMainMenu()
        installKeyMonitor()
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

        // Gated end-to-end probe for the search path: focus the field, type through the REAL event
        // path (a local monitor runs inside sendEvent), submit, and report where it breaks. Never
        // runs without MT_SELFTEST set.
        if let q = ProcessInfo.processInfo.environment["MT_SELFTEST"], !q.isEmpty { runSearchSelfTest(q) }
        if let v = ProcessInfo.processInfo.environment["MT_FSTEST"], !v.isEmpty { runFullscreenSelfTest(v) }
        // Dropdown probe: focus search and type WITHOUT submitting, so the suggestions dropdown
        // stays open for a window capture.
        if let q = ProcessInfo.processInfo.environment["MT_SUGTEST"], !q.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.store.focusSearchTick += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let codes: [Character: UInt16] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
                        "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,
                        "k":40,"n":45,"m":46," ":49]
                    // "-" = focus only (the recents view); anything else is typed as a partial query.
                    if q != "-" {
                        for ch in q.lowercased() {
                            guard let kc = codes[ch] else { continue }
                            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                                context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch),
                                isARepeat: false, keyCode: kc) { NSApp.sendEvent(ev) }
                        }
                    }
                    print("[sug] typed \"\(q)\" — dropdown should be open")
                }
            }
        }
        // Visionary-button probe: open a channel page and report the bridge's gating state, so a
        // window capture can show whether the capability-gated buttons actually rendered.
        if let cid = ProcessInfo.processInfo.environment["MT_VISTEST"], !cid.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self.store.openChannel(cid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    let b = VisionaryBridge.shared
                    print("[vis] available=\(b.available) capabilities=\(b.capabilities.sorted()) canChannel=\(b.canSend("channel")) canPlaylist=\(b.canSend("playlist"))")
                    let tabs = self.store.channelInfo?.tabs ?? []
                    print("[tabs] \(tabs.map(\.title))")
                    // Switch to the tab named by MT_TAB (default Playlists) and report what loaded.
                    let want = ProcessInfo.processInfo.environment["MT_TAB"] ?? "Playlists"
                    guard let t = tabs.first(where: { $0.title == want }) else { print("[tabs] no \(want) tab"); return }
                    self.store.openChannelTab(t)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        let v = self.store.videos
                        print("[tabs] after switching to \(want): \(v.count) items, playlists=\(v.filter { $0.playlistId != nil }.count), shorts=\(v.filter(\.isShort).count)")
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerSession.shared.stopKeepalive()
        backend.stop()   // tear down the backend we spawned
    }

    /// Closing the window QUITS. Previously this returned false ("keep running, reopen from the
    /// Dock"), which was actively broken: an NSWindow built with the designated initializer has
    /// isReleasedWhenClosed == true, so AppKit freed the window on close while the app lived on
    /// holding a dangling reference — and the Dock-icon reopen then messaged that freed window
    /// (EXC_BAD_ACCESS in applicationShouldHandleReopen; four crash reports on disk). It also left
    /// the Dock's running-dot lit after the user thought they'd closed the app, and because the
    /// crash was a SIGSEGV, applicationWillTerminate never ran, orphaning the spawned backend.
    /// Quitting on close makes the Dock dot honest AND runs the clean teardown above.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // NOTE: no applicationShouldHandleReopen — with quit-on-close there is no windowless-but-running
    // state to reopen into, and AppKit's default already unhides/deminiaturizes correctly.

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Arrow-key / Enter navigation, Plex-HTPC style.
    ///
    /// An NSApp-level LOCAL monitor rather than SwiftUI `.onKeyPress`: onKeyPress only fires on a
    /// focused view, and the watch page's WKWebView takes first responder the moment it is clicked,
    /// so SwiftUI would never see the arrows. A local monitor runs inside `sendEvent` — ahead of
    /// menu key-equivalents and every responder — so it can consume or forward deliberately. It is
    /// app-level, not window-level, because WebKit reparents the player into its own
    /// WebCoreFullScreenWindow for YouTube fullscreen.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .mouseMoved]) { event in
            MainActor.assumeIsolated { self.handle(event) }
        }
    }

    /// Keys held for the long-press commands (Plex: long Return = menu, long Back = home).
    private var heldKey: UInt16?
    private var heldFiredLong = false

    private func handle(_ event: NSEvent) -> NSEvent? {
        let engine = FocusEngine.shared
        let player = PlayerBridge.shared

        if event.type == .mouseMoved {
            engine.mouseTookOver()      // mouse wins: put the ring away
            return event
        }

        // Never touch a key that belongs to someone else:
        //  • any modifier combo (⌘F, ⌘Q, ⌘C, and Plex's own ⌘F search … all keep working)
        //  • text entry — SwiftUI's TextField editor is an NSTextView, so checking for
        //    NSTextField would silently miss it and eat caret movement
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !mods.isDisjoint(with: [.command, .option, .control]) { return event }
        let responder = NSApp.keyWindow?.firstResponder

        // TEXT ENTRY WINS, unconditionally. The Plex map claims bare letters (H home, X stop,
        // B back …) and Return, so a search box that does not get this right looks completely
        // broken: typing "how to" jumps home on the first letter and Return never reaches onSubmit.
        //
        // The signal is SwiftUI's own @FocusState, published by the search field. An earlier
        // `responder is NSTextView` check shipped instead and BROKE SEARCH COMPLETELY: a probe
        // reproducing this exact structure (NSHostingView + TextField + @FocusState + this monitor)
        // showed `NSApp.keyWindow?.firstResponder` reporting **nil** while the field genuinely had
        // focus, so the class never matched and every keystroke fell through to the command map —
        // "how" typed nothing and jumped home. @FocusState reported the truth in the same run.
        // See tools/keyguard-probe. The class check stays only as a secondary net.
        if event.type == .keyDown, MTDebug.enabled, engine.textEntry || responder is NSTextView {
            MTDebug.log("[keys] text entry — responder=\(responder.map { String(describing: type(of: $0)) } ?? "nil") focusState=\(engine.textEntry)")
        }
        if engine.textEntry {
            // Escape leaves the field rather than navigating back.
            if event.type == .keyDown, event.keyCode == 53, let blur = engine.blurText { blur(); return nil }
            return event
        }
        if responder is NSTextView { return event }

        // Web content splits two ways. The PLAYER is a control surface: Plex's letter commands must
        // work while it holds first responder, since that is exactly when you are watching. Any OTHER
        // web view is the Google sign-in form — swallowing letters there would break typing an email
        // or password — so it passes everything through untouched.
        let inPlayer = Self.isPlayerWebContent(responder)
        if !inPlayer, let r = responder as? NSView, Self.isWebContent(r) { return event }

        let code = event.keyCode
        let watching = store?.watchVideoId != nil

        // Leaving YouTube's element fullscreen comes before "back": in Plex, Back on a fullscreen
        // video drops you out of fullscreen, not out of the video. Escape is WebKit's own exit, so
        // hand it over; the other Back keys click the fullscreen button instead.
        if PlexKeyMap.backKeys.contains(code), player.isElementFullscreen {
            guard event.type == .keyDown else { return code == 53 ? event : nil }
            if code == 53 { return event }
            player.toggleFullscreen()
            return nil
        }

        // ── Long press: Return holds to `menu`, Back holds to `home` ───────────────────────────
        // macOS auto-repeat IS the long-press signal, so no timer is needed: the first repeat means
        // the key is still down past the repeat delay. The short action therefore has to wait for
        // key-up, or a long press would fire both.
        if PlexKeyMap.longPressKeys.contains(code) {
            switch event.type {
            case .keyDown:
                if event.isARepeat {
                    if !heldFiredLong, let long = PlexKeyMap.longPress(for: code) {
                        heldFiredLong = true
                        _ = perform(long, inPlayer: inPlayer, watching: watching)
                    }
                } else {
                    heldKey = code
                    heldFiredLong = false
                }
                return nil
            case .keyUp:
                defer { heldKey = nil; heldFiredLong = false }
                guard heldKey == code, !heldFiredLong,
                      let short = PlexKeyMap.command(for: code) else { return nil }
                return perform(short, inPlayer: inPlayer, watching: watching) ? nil : event
            default:
                return event
            }
        }
        guard event.type == .keyDown, let command = PlexKeyMap.command(for: code) else { return event }
        return perform(command, inPlayer: inPlayer, watching: watching) ? nil : event
    }

    /// Run one Plex command. Returns whether it was consumed; anything that had nowhere to go falls
    /// through to the normal responder chain rather than being silently eaten.
    private func perform(_ command: PlexCommand, inPlayer: Bool, watching: Bool) -> Bool {
        let engine = FocusEngine.shared
        let player = PlayerBridge.shared

        // Commands that act on a video need one open. `inPlayer` doesn't imply it during teardown,
        // so both are checked.
        if PlexKeyMap.needsVideo(command), !watching { return false }

        switch command {
        case .navigate(let d):
            // In the player these belong to YouTube, whose native ±5s seek and volume are exactly
            // what Plex's arrows do there — so they pass straight through rather than being remapped.
            if inPlayer { return false }
            return engine.handle(direction: d)

        case .activate:
            // Return in the player is play/pause (YouTube binds Space and k, but not Return).
            if inPlayer || (watching && engine.focused == nil) { player.playPause(); return true }
            return engine.handleActivate()

        case .back:   return engine.handleEscape()
        case .home:   store?.goHome(); return true
        case .menu:   engine.requestMenu(); return true
        case .info:
            guard let showInfo = engine.showInfo else { return false }
            showInfo(); return true

        case .playPause:
            if inPlayer { return false }        // YouTube already binds Space itself
            player.playPause(); return true
        case .stop:              store?.goBack(); return true
        case .seek(let d):       player.seek(d); return true
        case .step(let d):       player.step(d); return true
        case .volume(let d):     player.volume(d); return true
        case .toggleSubtitles:   player.toggleSubtitles(); return true
        case .toggleFullscreen:  player.toggleFullscreen(); return true
        case .toggleWatched:
            guard let id = store?.watchVideoId else { return false }
            store?.markWatched(id); return true
        case .cycleTab(let d):
            guard let cycle = engine.cycleTab else { return false }
            cycle(d); return true
        }
    }

    /// End-to-end probe of the search path. Reports each stage so a failure says WHICH stage.
    private func runSearchSelfTest(_ query: String) {
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        var consumed: [UInt16] = [], seen: [UInt16] = []
        let spy = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            MainActor.assumeIsolated { seen.append(e.keyCode) }; return e
        }
        after(5) {
            print("[selftest] --- stage 1: focus ---")
            print("[selftest] textEntry before focus = \(FocusEngine.shared.textEntry)")
            self.store.focusSearchTick += 1
            after(0.6) {
                print("[selftest] textEntry after focus  = \(FocusEngine.shared.textEntry)   <- must be true")
                print("[selftest] --- stage 2: type \"\(query)\" through the real event path ---")
                let codes: [Character: UInt16] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
                    "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,
                    "k":40,"n":45,"m":46," ":49]
                for ch in query.lowercased() {
                    guard let kc = codes[ch] else { continue }
                    let before = seen.count
                    if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                        context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch),
                        isARepeat: false, keyCode: kc) {
                        NSApp.sendEvent(ev)
                        if seen.count == before { consumed.append(kc) }
                    }
                }
                print("[selftest] keys the monitor swallowed: \(consumed.isEmpty ? "none" : String(describing: consumed))")
                print("[selftest] --- stage 3: submit ---")
                if let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                    NSApp.sendEvent(ret)
                }
                after(4) {
                    print("[selftest] --- stage 4: result ---")
                    print("[selftest] store.searchQuery = \"\(self.store.searchQuery)\"  (expected \"\(query)\")")
                    print("[selftest] store.videos.count = \(self.store.videos.count)")
                    print("[selftest] VERDICT: " + (self.store.searchQuery == query && self.store.videos.count > 0
                          ? "search works" : "SEARCH BROKEN"))
                    if let spy { NSEvent.removeMonitor(spy) }
                    // MT_SELFTEST_HOLD keeps the window up for a screenshot.
                    if ProcessInfo.processInfo.environment["MT_SELFTEST_HOLD"] == nil { exit(0) }
                }
            }
        }
    }

    /// Probe for YouTube's on-screen fullscreen button: is it there, is anything covering it, and
    /// does a REAL click (a synthesized NSEvent, which WebKit treats as a genuine user gesture —
    /// unlike a JS-dispatched MouseEvent) actually enter fullscreen?
    private func runFullscreenSelfTest(_ videoId: String) {
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        let hadAuto = ProcessInfo.processInfo.environment["MT_FSTEST_AUTO"] != "keep"
        if hadAuto { self.store.setAutoFullscreen(false) }   // restored by the caller script
        after(4) {
            self.store.openWatch(videoId)
            after(10) {
                guard let wv = PlayerBridge.shared.webView else { print("[fs] NO player web view"); return }
                let probe = """
                (function(){
                  var b=document.querySelector('.ytp-fullscreen-button');
                  if(!b) return JSON.stringify({button:false});
                  var r=b.getBoundingClientRect();
                  var cx=r.left+r.width/2, cy=r.top+r.height/2;
                  var top=document.elementFromPoint(cx,cy);
                  return JSON.stringify({button:true, rect:[Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)],
                    cx:Math.round(cx), cy:Math.round(cy),
                    topEl: top ? (top.className||top.tagName) : null,
                    hitsButton: !!(top && (top===b || b.contains(top) || (top.closest && top.closest('.ytp-fullscreen-button')))),
                    fsEnabled: !!(document.fullscreenEnabled), inFs: !!(document.fullscreenElement),
                    vw: window.innerWidth, vh: window.innerHeight});
                })()
                """
                // Record what the PAGE actually receives, so a failed click can be told apart from a
                // click that never arrived.
                wv.evaluateJavaScript("""
                    window.__mtEv=[];
                    ['mousedown','mouseup','click'].forEach(function(n){
                      document.addEventListener(n, function(e){
                        window.__mtEv.push(n+'@'+Math.round(e.clientX)+','+Math.round(e.clientY)+
                          ' on '+((e.target&&(e.target.className||e.target.tagName))||'?')+
                          (e.isTrusted?' trusted':' synthetic'));
                      }, true);
                    }); 'ok'
                """, completionHandler: nil)
                wv.evaluateJavaScript(probe) { res, err in
                    print("[fs] probe: \(res ?? (err?.localizedDescription as Any))")
                    guard let json = res as? String,
                          let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                          let cx = d["cx"] as? Int, let cy = d["cy"] as? Int else { return }
                    // Synthesize a real click at the button, in window coordinates (AppKit origin is
                    // bottom-left; the web rect is top-left within the web view).
                    let inWV = NSPoint(x: CGFloat(cx), y: wv.bounds.height - CGFloat(cy))
                    let inWin = wv.convert(inWV, to: nil)
                    print("[fs] wv.bounds=\(wv.bounds) inWV=\(inWV) inWin=\(inWin) wvWindow=\(wv.window?.windowNumber ?? -1) mainWindow=\(self.window.windowNumber)")
                    // A trusted OS-level click cannot be synthesized from inside the app (NSEvent
                    // and CGEvent both verified undelivered to web content). But the interceptor
                    // path can be driven exactly: an in-page .click() fires the same capture-phase
                    // listener a real click does, which posts fullscreen-request to the host, which
                    // re-clicks with the pass flag — the path the user's click takes.
                    _ = inWin   // (kept for the geometry printout above)
                    wv.evaluateJavaScript("document.querySelector('.ytp-fullscreen-button').click(); 'clicked'") { r, e in
                        print("[fs] in-page click dispatched: \(r ?? e?.localizedDescription ?? "nil")")
                    }
                    after(2.5) {
                        wv.evaluateJavaScript("JSON.stringify(window.__mtEv||[])") { ev, _ in print("[fs] page received: \(ev ?? "nil")") }
                        wv.evaluateJavaScript("JSON.stringify({inFs:!!document.fullscreenElement, w:window.innerWidth, h:window.innerHeight})") { r2, _ in
                            print("[fs] after real click: \(r2 ?? "nil")")
                            print("[fs] VERDICT: " + (((r2 as? String)?.contains("\"inFs\":true")) == true ? "button works" : "BUTTON DOES NOT ENTER FULLSCREEN"))
                        }
                    }
                }
            }
        }
    }

    /// True when the keystroke is going to the video player specifically (as opposed to the sign-in
    /// web view), which is what makes it safe to claim letter keys.
    private static func isPlayerWebContent(_ responder: Any?) -> Bool {
        guard let target = PlayerBridge.shared.webView, let view = responder as? NSView else { return false }
        var v: NSView? = view
        while let cur = v {
            if cur === target { return true }
            v = cur.superview
        }
        return false
    }

    /// True when this view (or an ancestor) is a web view — i.e. the keystroke belongs to the page.
    private static func isWebContent(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let cur = v {
            if cur is WKWebView { return true }
            v = cur.superview
        }
        return false
    }

    /// The app shipped with NO menu bar at all, so there was no ⌘Q, ⌘W, or even ⌘C — despite the
    /// title/description being selectable text and the header having a search field. Install the
    /// standard responder-driven menus.
    private func buildMainMenu() {
        let name = "SmartTube"
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
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
