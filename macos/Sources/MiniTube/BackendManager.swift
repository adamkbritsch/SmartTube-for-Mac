import Foundation
import Darwin

/// Launches (and tears down) the Vapor backend so the app is self-contained —
/// double-click and go, no terminal. If a backend is already serving (e.g. one
/// started by hand during development), it is reused instead of spawning a second.
///
/// Crash-safety: the spawned pid is recorded to a pidfile. On the next launch a
/// backend we leaked on crash (stop() never ran) is reaped instead of reused, so
/// we never inherit stale code or a wedged port 8080.
@MainActor
final class BackendManager {
    private var process: Process?
    private let health = URL(string: "http://127.0.0.1:8080/api/health")!

    private static var pidfileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YouTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backend.pid")
    }

    /// Path to the built backend binary. The app bundle carries a copy under
    /// Resources/Server/; in a plain `swift run` dev build we fall back to the
    /// repo's release build product (resolved from this file's compile-time path).
    private static var backendBinary: String? {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("Server/App").path
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        }
        // <repo>/macos/Sources/MiniTube/BackendManager.swift → <repo>/backend/.build/release/App
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MiniTube
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // <repo>
        let dev = repo.appendingPathComponent("backend/.build/release/App").path
        return FileManager.default.isExecutableFile(atPath: dev) ? dev : nil
    }

    /// Spawn the backend unless one is already up. Non-blocking.
    func startIfNeeded() {
        Task {
            await reapOrphanedBackend()
            if await isUp() {
                print("[YouTube] backend already running — reusing it")
                adoptRunningBackend()   // record it so a future crash-leak is reapable
                return
            }
            spawn()
        }
    }

    /// Pidfile format: "backendPid:ownerPid". The owner is the app instance that
    /// spawned (or adopted) the backend — reaping keys off the OWNER being dead,
    /// so a second app instance never SIGTERMs a healthy sibling's backend.
    private func reapOrphanedBackend() async {
        let url = BackendManager.pidfileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        let pid = parts.first.flatMap { Int32($0) } ?? 0
        let owner = parts.count > 1 ? (Int32(parts[1]) ?? 0) : 0

        // Owner still alive → the backend belongs to a live sibling instance. Leave both alone.
        if owner > 0, kill(owner, 0) == 0, owner != ProcessInfo.processInfo.processIdentifier {
            print("[YouTube] backend owned by live instance \(owner) — not reaping")
            return
        }
        // Owner dead (crash-leak). Reap the backend if it's really ours and alive.
        try? FileManager.default.removeItem(at: url)
        guard pid > 0, kill(pid, 0) == 0,
              pidExecutablePath(pid) == BackendManager.backendBinary else { return }

        print("[YouTube] reaping orphaned backend (pid \(pid))")
        kill(pid, SIGTERM)
        for _ in 0..<20 {                       // up to ~2s for it to release the port
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }   // stubborn — force it
    }

    /// A healthy backend with no live owner (started by hand, or its owner died
    /// without leaking) gets recorded under OUR pid so its lifecycle is tracked.
    private func adoptRunningBackend() {
        let url = BackendManager.pidfileURL
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            if parts.count > 1, let owner = Int32(parts[1]), owner > 0, kill(owner, 0) == 0,
               owner != ProcessInfo.processInfo.processIdentifier { return }   // sibling owns it
        }
        guard let bin = BackendManager.backendBinary, let pid = findBackendPid(binary: bin) else { return }
        writePidfile(backend: pid)
        print("[YouTube] adopted running backend (pid \(pid))")
    }

    /// Locate a live process running our backend binary (bounded scan of all pids).
    private func findBackendPid(binary: String) -> Int32? {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return nil }
        for pid in pids.prefix(Int(n)) where pid > 0 {
            if pidExecutablePath(pid) == binary { return pid }
        }
        return nil
    }

    private func writePidfile(backend pid: Int32) {
        let owner = ProcessInfo.processInfo.processIdentifier
        try? "\(pid):\(owner)".write(to: BackendManager.pidfileURL, atomically: true, encoding: .utf8)
    }

    private func pidExecutablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    private func spawn() {
        guard let bin = BackendManager.backendBinary else {
            print("[YouTube] backend binary not found — build it (swift build -c release) or repackage")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "8080"]
        // Capture backend output (auth/InnerTube failures were previously invisible
        // in the field). Truncated at every spawn so it can't grow unbounded.
        let logURL = BackendManager.pidfileURL.deletingLastPathComponent().appendingPathComponent("backend.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)   // truncate
        let logHandle = FileHandle(forWritingAtPath: logURL.path)
        p.standardOutput = logHandle ?? FileHandle.nullDevice
        p.standardError = logHandle ?? FileHandle.nullDevice
        do {
            try p.run()
            process = p
            writePidfile(backend: p.processIdentifier)
            print("[YouTube] backend spawned (pid \(p.processIdentifier)) from \(bin), log: \(logURL.path)")
        } catch {
            print("[YouTube] failed to spawn backend: \(error)")
        }
    }

    private func isUp() async -> Bool {
        var req = URLRequest(url: health); req.timeoutInterval = 1.5
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200 { return true }
        return false
    }

    /// Terminate the backend we own and wait (bounded) for it to actually exit —
    /// a fast quit→relaunch must not "reuse" a half-dead server or race port 8080.
    func stop() {
        guard let p = process else {
            try? FileManager.default.removeItem(at: BackendManager.pidfileURL)
            return
        }
        let pid = p.processIdentifier
        p.terminate()
        process = nil
        for _ in 0..<20 {                       // up to ~2s
            if kill(pid, 0) != 0 { break }
            usleep(100_000)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: BackendManager.pidfileURL)
    }
}
