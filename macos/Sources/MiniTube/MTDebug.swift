import Foundation

/// Central switch for on-disk diagnostics. A release build writes NOTHING unless
/// the flag file exists at launch (`touch /tmp/mt-debug`), which also truncates
/// the log so each debugging session starts clean. Checked once — zero per-call
/// filesystem probes on the hot paths that log.
enum MTDebug {
    static let logPath = "/tmp/youtube-player-debug.log"
    static let enabled: Bool = FileManager.default.fileExists(atPath: "/tmp/mt-debug")

    /// Call once at app startup: begin the session with an empty log (when enabled).
    static func startSession() {
        guard enabled else { return }
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        log("[debug] session start \(Date())")
    }

    /// Append one diagnostic line (no-op unless the flag file was present at launch).
    static func log(_ msg: String) {
        guard enabled else { return }
        let line = msg.hasSuffix("\n") ? msg : msg + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}
