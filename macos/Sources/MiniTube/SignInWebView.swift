import SwiftUI
import WebKit

/// The real Google sign-in, hosted INSIDE the app's own persistent session store. Whatever the
/// user logs into here becomes the app's self-rotating session (the player + backend consume the
/// same store) — no Firefox involved. Loading youtube.com as the `continue` target also lets
/// YouTube (re)set LOGIN_INFO, which repairs a session that had valid Google cookies but a stale
/// YouTube content login. If Google refuses the embedded login ("this browser may not be secure"),
/// `onBlocked` fires and the sheet offers the one-time Firefox fallback.
struct SignInWebView: NSViewRepresentable {
    var onSuccess: () -> Void
    var onBlocked: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSuccess: onSuccess, onBlocked: onBlocked) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = PlayerSession.shared.store   // sign in on the app's OWN store
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        // Safari UA — Google's "browser may not be secure" gate keys partly on the UA (the player
        // deliberately uses a Chrome UA for codecs; these stay independent).
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        if let url = URL(string: "https://accounts.google.com/ServiceLogin?continue=https://www.youtube.com/") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSuccess: () -> Void
        let onBlocked: () -> Void
        private var done = false
        init(onSuccess: @escaping () -> Void, onBlocked: @escaping () -> Void) {
            self.onSuccess = onSuccess; self.onBlocked = onBlocked
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done else { return }
            let host = webView.url?.host ?? ""
            // Landed on youtube.com — the `continue` redirect only fires after a completed login.
            if host.contains("youtube.com") { done = true; onSuccess(); return }
            // Otherwise sniff for Google's embedded-login block page.
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                guard let self, !self.done else { return }
                let text = (result as? String ?? "").lowercased()
                if text.contains("browser or app may not be secure")
                    || text.contains("couldn’t sign you in") || text.contains("couldn't sign you in") {
                    self.done = true; self.onBlocked()
                }
            }
        }
    }
}
