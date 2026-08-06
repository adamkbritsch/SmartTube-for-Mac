import Foundation

/// Hands a video to Visionary — the user's 4K Dolby Vision upscaling app — which runs a localhost
/// engine on :8765 when it's installed and running. The button that uses this only appears while
/// that engine answers, so the app never shows a control that can't do anything.
///
/// Fire-and-forget by design: Visionary asks its NAS-side downloader to fetch the video, then
/// upscales it as the next item in its queue. That takes a long time, so this reports a one-shot
/// result and never tries to track progress.
@MainActor
final class VisionaryBridge: ObservableObject {
    static let shared = VisionaryBridge()

    private let stateURL = URL(string: "http://127.0.0.1:8765/api/state")!
    private let sendURL = URL(string: "http://127.0.0.1:8765/api/send-to-visionary")!

    /// Whether Visionary's engine answered recently. Drives button visibility.
    @Published private(set) var available = false
    private var checkedAt = Date.distantPast
    private let ttl: TimeInterval = 60
    private var probe: Task<Void, Never>?

    /// One-shot outcome of a send, mapped from the endpoint's `status`.
    enum SendResult: Equatable {
        case queued            // will be upscaled next in the pipeline
        case alreadyQueued
        case alreadyUpscaled
        case failed(String)    // message to show on the button

        var isError: Bool { if case .failed = self { return true }; return false }

        var label: String {
            switch self {
            case .queued:          return "Sent to Visionary"
            case .alreadyQueued:   return "Already queued"
            case .alreadyUpscaled: return "Already upscaled"
            case .failed(let m):   return m
            }
        }
        var symbol: String {
            switch self {
            case .failed:          return "exclamationmark.triangle.fill"
            case .alreadyUpscaled: return "checkmark.seal"
            default:               return "checkmark"
            }
        }
    }

    /// Refresh availability at most once per TTL. Never blocks the caller or the UI: the probe runs
    /// detached with a short timeout, and `available` simply flips when it answers.
    func refreshAvailability(force: Bool = false) {
        guard force || Date().timeIntervalSince(checkedAt) > ttl else { return }
        guard probe == nil else { return }
        probe = Task { [weak self] in
            guard let self else { return }
            var req = URLRequest(url: stateURL)
            req.timeoutInterval = 2
            req.httpMethod = "GET"
            let up: Bool
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                up = true
            } else {
                up = false
            }
            self.checkedAt = Date()
            self.probe = nil
            if self.available != up {
                self.available = up
                print("[Visionary] engine \(up ? "available" : "not running")")
            }
        }
    }

    /// Hand one video to Visionary's pipeline. Idempotent server-side, so a double click is safe.
    func send(videoId: String, title: String) async -> SendResult {
        struct Body: Encodable { let url: String; let title: String }
        struct Reply: Decodable { let status: String; let id: String? }

        var req = URLRequest(url: sendURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(
            Body(url: "https://www.youtube.com/watch?v=\(videoId)", title: title))

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            available = false            // it's gone; hide the button until the next probe
            return .failed("Visionary not responding")
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return .failed(http.statusCode == 200 ? "Unexpected reply" : "Visionary error \(http.statusCode)")
        }
        switch reply.status {
        case "queued":              return .queued
        case "already-queued":      return .alreadyQueued
        case "already-upscaled":    return .alreadyUpscaled
        case "youtarr-unreachable": return .failed("Downloader unreachable — try again")
        case "bad-url":             return .failed("Visionary rejected the link")
        default:                    return .failed("Visionary: \(reply.status)")
        }
    }
}
