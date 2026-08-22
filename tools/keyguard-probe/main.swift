import AppKit
import SwiftUI

// Reproduces the app's exact structure: NSHostingView + SwiftUI TextField + @FocusState, with the
// same app-level local key monitor. Drives it with synthetic NSEvents through NSApp.sendEvent, which
// is the same path real keystrokes take (a local monitor runs INSIDE sendEvent). The window is
// parked far off-screen so nothing is ever visible.

final class Probe: ObservableObject {
    static let shared = Probe()
    var textEntry = false                 // what the fixed guard uses (@FocusState-driven)
    @Published var text = ""
    var swallowed: [String] = []          // keys the monitor consumed
    var responderClasses: Set<String> = []
}

struct Field: View {
    @ObservedObject var probe = Probe.shared
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Search", text: $probe.text)
            .focused($focused)
            .onChange(of: focused) { _, on in Probe.shared.textEntry = on }
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } }
            .frame(width: 300)
    }
}

// The command map's letter keys, as in PlexKeyMap.
let commandCodes: Set<UInt16> = [4 /*H*/, 31 /*O*/, 13 /*W*/, 36 /*Return*/]

@MainActor final class D: NSObject, NSApplicationDelegate {
    var w: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        w = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 400, height: 80),
                     styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: Field())
        w.makeKeyAndOrderFront(nil)

        _ = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            MainActor.assumeIsolated {
                let p = Probe.shared
                let r = NSApp.keyWindow?.firstResponder
                p.responderClasses.insert(r.map { String(describing: type(of: $0)) } ?? "nil")
                let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !mods.isDisjoint(with: [.command, .option, .control]) { return e }

                let classGuardWouldPass = r is NSTextView            // the OLD guard
                let focusGuardWouldPass = p.textEntry                // the NEW guard
                if ProcessInfo.processInfo.environment["GUARD"] == "old" {
                    if classGuardWouldPass { return e }
                } else {
                    if focusGuardWouldPass { return e }
                }
                if commandCodes.contains(e.keyCode) { p.swallowed.append("kc\(e.keyCode)"); return nil }
                return e
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.drive() }
    }

    func send(_ code: UInt16, _ ch: String) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil,
                                       characters: ch, charactersIgnoringModifiers: ch,
                                       isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(e)
    }

    func drive() {
        let p = Probe.shared
        // type "how"  (H=4, O=31, W=13) then Return(36)
        send(4, "h"); send(31, "o"); send(13, "w"); send(36, "\r")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let guardMode = ProcessInfo.processInfo.environment["GUARD"] ?? "new"
            print("GUARD=\(guardMode)")
            print("  firstResponder classes seen: \(p.responderClasses.sorted())")
            print("  @FocusState reported textEntry: \(p.textEntry)")
            print("  keys swallowed by command map: \(p.swallowed)")
            print("  text that reached the field:   \"\(p.text)\"")
            print(p.swallowed.isEmpty && p.text == "how" ? "  RESULT: typing works" : "  RESULT: TYPING BROKEN")
            NSApp.terminate(nil)
        }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let d = D(); app.delegate = d
    app.setActivationPolicy(.accessory)      // no Dock icon, minimal disruption
    app.run()
    _ = d
}
