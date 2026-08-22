# keyguard-probe

A 2-second regression check for the one bug that makes the app look completely broken: the
Plex-HTPC key map (`PlexKeyMap.swift`) claims bare letters — `H` home, `X` stop, `B` back — and
`Return`. If the monitor's text-entry guard ever stops working, typing "how to" in the search box
jumps home on the first letter and `Return` never reaches `onSubmit`.

That shipped once. The guard was `NSApp.keyWindow?.firstResponder is NSTextView`, and this probe is
what showed why it failed: the responder reports **nil** while a SwiftUI `TextField` genuinely has
focus, so the check never matched. The fix drives the guard from SwiftUI's own `@FocusState`.

The probe rebuilds that exact structure — `NSHostingView` + `TextField` + `@FocusState` + an
app-level `addLocalMonitorForEvents` — types "how" and `Return` through `NSApp.sendEvent` (the same
path real keystrokes take, since a local monitor runs inside it), and reports whether the text
arrived. The window is parked at -9000,-9000 and the app is `.accessory`, so nothing is ever visible.

```
swiftc -o kt main.swift && ./kt          # the guard as it ships — expect "typing works"
GUARD=old ./kt                            # the broken class check — expect "TYPING BROKEN"
```

Both modes are kept so the probe proves it can still detect the failure, not just report success.
