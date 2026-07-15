import SwiftUI
import WebKit

/// A webkit-extension:// page (the extension's own dashboard/options) only loads
/// when the controller has a window → tab model to give it an execution context;
/// without one WebKit refuses the resource with NSURLError -1008. These minimal
/// host objects present the settings WKWebView to the controller as a single tab
/// in a single window.
@available(macOS 15.4, *)
final class ExtHostTab: NSObject, WKWebExtensionTab {
    private(set) weak var hostView: WKWebView?
    weak var host: ExtHostWindow?
    init(_ webView: WKWebView) { self.hostView = webView }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { hostView }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { host }
    func url(for context: WKWebExtensionContext) -> URL? { hostView?.url }
    func title(for context: WKWebExtensionContext) -> String? { hostView?.title }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
}

@available(macOS 15.4, *)
final class ExtHostWindow: NSObject, WKWebExtensionWindow {
    var tab: ExtHostTab?
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tab.map { [$0] } ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
}

/// Hosts a WebExtension's own settings page (uBlock Origin Lite dashboard /
/// SponsorBlock options) in a WKWebView wired to the same extension controller,
/// so the page's storage reads/writes actually drive the running extension.
@available(macOS 15.4, *)
private struct ExtensionSettingsWeb: NSViewRepresentable {
    let url: URL
    let controller: WKWebExtensionController
    let extContext: WKWebExtensionContext
    var readableTextFix = false   // uBO panes: half-applied theme leaves dark-on-dark labels

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    /// Escape a CSS block as a JS string literal (JSON string == valid JS string).
    private func cssLiteral(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
           let out = String(data: d, encoding: .utf8) { return out }
        return "''"
    }

    func makeNSView(context: Context) -> WKWebView {
        // Apple: webkit-extension:// pages load ONLY in web views built from the
        // context's own vended configuration — "navigations are canceled if other
        // web views attempt to access extension URLs" (the -1008 we saw).
        let config = extContext.webViewConfiguration ?? {
            let c = WKWebViewConfiguration()
            c.webExtensionController = controller
            return c
        }()
        ExtLog.write("using vended config=\(extContext.webViewConfiguration != nil)")
        // Capture the page's own JS errors so a blank SPA is diagnosable.
        let errHook = WKUserScript(source: """
            window.__mtErrs = [];
            window.addEventListener('error', e => window.__mtErrs.push(String(e.message||e)));
            window.addEventListener('unhandledrejection', e => window.__mtErrs.push('rejection: ' + String(e.reason)));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(errHook)
        if readableTextFix {
            // uBO pane pages evaluate webext.js too, which dies on the missing
            // chrome.privacy — same stub the background gets via mt-shim.js.
            let privacyStub = WKUserScript(source: """
                (function(){
                  var mk = function(dv){ return {
                    get: function(d, cb){ var r = {value: dv, levelOfControl: 'not_controllable'}; if(cb) cb(r); return Promise.resolve(r); },
                    set: function(d, cb){ if(cb) cb(); return Promise.resolve(); },
                    clear: function(d, cb){ if(cb) cb(); return Promise.resolve(); },
                    onChange: { addListener: function(){}, removeListener: function(){}, hasListener: function(){ return false; } } }; };
                  var stub = { network: { networkPredictionEnabled: mk(false), webRTCIPHandlingPolicy: mk('default') },
                               websites: { hyperlinkAuditingEnabled: mk(false) } };
                  try { if (typeof chrome !== 'undefined' && !chrome.privacy) chrome.privacy = stub; } catch(e){}
                  try { if (typeof browser !== 'undefined' && !browser.privacy) browser.privacy = stub; } catch(e){}
                })();
                """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(privacyStub)
            // uBO's theme JS dies mid-chain under WebKit (storage-usage API rejections),
            // leaving its dark background with unresolved (dark) label colors. Force
            // legible text — uBO's own dark palette values, applied unconditionally.
            let css = """
            :root { color-scheme: dark; }
            body, body * { color: #e6e6ea !important; }
            a { color: #82b6ff !important; }
            h2, h3, .fieldset-header, legend { color: #ffffff !important; }
            input[type=text], input[type=number], textarea, select {
                color: #e6e6ea !important; background-color: #17171d !important; }
            """
            let themeFix = WKUserScript(source: """
                (function(){ var s = document.createElement('style');
                  s.textContent = \(cssLiteral(css));
                  (document.head || document.documentElement).appendChild(s); })();
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            config.userContentController.addUserScript(themeFix)

            // Export/backup buttons call vAPI.download, which builds a DETACHED
            // <a download href="data:..."> and dispatches a click — WKWebView does
            // nothing with that. Intercept at the prototype level (before vAPI loads)
            // and route the payload to the app for a native Save panel.
            let downloadHook = WKUserScript(source: """
                (function(){
                  var orig = HTMLAnchorElement.prototype.dispatchEvent;
                  HTMLAnchorElement.prototype.dispatchEvent = function(ev){
                    try {
                      if (this.hasAttribute('download') && this.href && ev && ev.type === 'click') {
                        window.webkit.messageHandlers.mtfile.postMessage(
                          { kind: 'save', url: this.href, filename: this.getAttribute('download') || 'download.txt' });
                        return true;
                      }
                    } catch(e){}
                    return orig.apply(this, arguments);
                  };
                })();
                """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(downloadHook)
            config.userContentController.add(context.coordinator, name: "mtfile")
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator          // file-import open panels
        context.coordinator.attach(webView: webView)   // register a window/tab before loading
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url { nsView.load(URLRequest(url: url)) }
    }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKWebExtensionControllerDelegate, WKUIDelegate, WKScriptMessageHandler {
        let controller: WKWebExtensionController
        let window = ExtHostWindow()
        private var tab: ExtHostTab?
        init(controller: WKWebExtensionController) { self.controller = controller }

        // MARK: File import (WKUIDelegate) — uBO's Import/Restore trigger a hidden
        // <input type=file>.click(); WKWebView shows no panel without this.
        func webView(_ webView: WKWebView,
                     runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.begin { resp in
                completionHandler(resp == .OK ? panel.urls : nil)
            }
        }

        // MARK: JS dialogs — uBO's Reset/Purge/Restore gate on confirm(); WKWebView
        // drops these unless the UI delegate services them.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let a = NSAlert(); a.messageText = "uBlock Origin"; a.informativeText = message
            a.addButton(withTitle: "OK"); a.runModal(); completionHandler()
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let a = NSAlert(); a.messageText = "uBlock Origin"; a.informativeText = message
            a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
            completionHandler(a.runModal() == .alertFirstButtonReturn)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let a = NSAlert(); a.messageText = "uBlock Origin"; a.informativeText = prompt
            a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = defaultText ?? ""; a.accessoryView = field
            completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }

        // uBO opens some links (advanced settings, wiki) via window.open — load them
        // in the same view rather than dropping them (returns nil = no new webview).
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }

        // MARK: File export (WKScriptMessageHandler "mtfile") — vAPI.download payload
        // → native Save panel → write. The save panel IS the user's per-action consent.
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mtfile",
                  let body = message.body as? [String: Any],
                  (body["kind"] as? String) == "save",
                  let urlStr = body["url"] as? String else { return }
            let filename = (body["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "uBlock-backup.txt"
            guard let data = Self.decodeDataURL(urlStr) else {
                ExtLog.write("save: could not decode data URL"); return
            }
            // Self-test: prove the intercept + decode round-trip without a modal panel.
            if FileManager.default.fileExists(atPath: "/tmp/mt-ubo-test") {
                ExtLog.write("DLTEST intercepted save '\(filename)' decoded \(data.count) bytes")
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.canCreateDirectories = true
            panel.begin { resp in
                guard resp == .OK, let dst = panel.url else { return }
                do { try data.write(to: dst); ExtLog.write("save OK → \(dst.lastPathComponent) (\(data.count) bytes)") }
                catch { ExtLog.write("save FAILED: \(error)") }
            }
        }

        /// Decode a `data:[<mime>][;base64],<payload>` URL (uBO uses text/plain, URL-encoded).
        static func decodeDataURL(_ s: String) -> Data? {
            guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") else { return nil }
            let meta = s[s.index(s.startIndex, offsetBy: 5)..<comma]
            let payload = String(s[s.index(after: comma)...])
            if meta.contains("base64") {
                return Data(base64Encoded: payload)
            }
            return payload.removingPercentEncoding?.data(using: .utf8)
        }

        /// Build the window/tab around the settings web view and register it with the shared
        /// controller delegate (owned by UBlockLoader) — so the player tab keeps working while
        /// the dashboard is open, and isn't torn down when it closes.
        func attach(webView: WKWebView) {
            let tab = ExtHostTab(webView)
            tab.host = window
            window.tab = tab
            self.tab = tab
            UBlockLoader.shared.registerHostWindow(window, tab: tab)
        }

        func detach() {
            if let tab { UBlockLoader.shared.unregisterHostWindow(window, tab: tab) }
        }

        // MARK: WKNavigationDelegate — did the extension page actually load?
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            // Diagnostics only: nothing runs in a normal (non-debug) session.
            guard MTDebug.enabled else { return }
            ExtLog.write("options didFinish url=\(w.url?.absoluteString ?? "?")")
            // Comprehensive mechanism self-test (touch /tmp/mt-ubo-test): cycle every
            // uBO pane and exercise every control non-destructively.
            if FileManager.default.fileExists(atPath: "/tmp/mt-ubo-test") { runMechanismTest(w); return }
            measure(w, tag: "t0")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak w] in
                guard let w else { return }
                self.measure(w, tag: "t3")
                self.probeBackground(w)
            }
        }

        // MARK: Mechanism self-test
        private static let testPanes = ["settings.html", "3p-filters.html", "1p-filters.html", "whitelist.html", "support.html"]
        private var testedPanes = Set<String>()

        private func runMechanismTest(_ w: WKWebView) {
            guard let cur = w.url?.lastPathComponent, Self.testPanes.contains(cur) else { return }
            // let the pane finish its own async init before probing
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak w] in
                guard let self, let w else { return }
                w.callAsyncJavaScript(Self.mechanismProbeJS, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let v): ExtLog.write("MECH[\(cur)] \(v as? String ?? String(describing: v))")
                    case .failure(let e): ExtLog.write("MECH[\(cur)] FAILED \(e)")
                    }
                    self.testedPanes.insert(cur)
                    if let next = Self.testPanes.first(where: { !self.testedPanes.contains($0) }), let base = w.url {
                        w.load(URLRequest(url: base.deletingLastPathComponent().appendingPathComponent(next)))
                    } else {
                        // Final: prove the vAPI.download → mtfile → decode path end-to-end.
                        w.evaluateJavaScript("vAPI.download({url:'data:text/plain;charset=utf-8,'+encodeURIComponent('mt-download-roundtrip-ok'), filename:'mt-test.txt'}); 'sent'") { _, _ in }
                        ExtLog.write("MECH done — all panes tested")
                    }
                }
            }
        }

        /// Non-destructive: stubs messaging/confirm/window.open/file-picker so clicking
        /// every control reveals WHAT it fires without committing anything.
        private static let mechanismProbeJS = """
        var report = { pane: location.pathname.split('/').pop(), controls: [], checkboxes: {} };
        var log = { msgs: [], files: [] };
        var realSend = null;
        try { if (window.vAPI && vAPI.messaging && typeof vAPI.messaging.send === 'function') {
            realSend = vAPI.messaging.send;
            vAPI.messaging.send = function(ch, msg){ log.msgs.push((msg && msg.what) || '?'); return Promise.resolve({}); };
        } } catch(e){}
        var realFileClick = HTMLInputElement.prototype.click;
        HTMLInputElement.prototype.click = function(){ if (this.type === 'file'){ log.files.push(this.id || 'file'); return; } return realFileClick.apply(this, arguments); };
        var realConfirm = window.confirm, realAlert = window.alert, realOpen = window.open;
        window.confirm = function(){ log.msgs.push('confirm()'); return false; };
        window.alert = function(){};
        window.open = function(u){ log.msgs.push('open:' + String(u).slice(0,40)); return null; };
        var stopNav = function(e){ var a = e.target && e.target.closest && e.target.closest('a[href]');
            if (a){ e.preventDefault(); e.stopPropagation(); log.msgs.push('nav:' + (a.getAttribute('href')||'').slice(0,32)); } };
        document.addEventListener('click', stopNav, true);
        var btns = Array.prototype.slice.call(document.querySelectorAll('button, .push-button, a.push-button, [data-i18n][type=button]'));
        for (var i = 0; i < btns.length; i++){
            var b = btns[i];
            var m0 = log.msgs.length, f0 = log.files.length, h0 = document.body.innerHTML.length;
            var label = (b.getAttribute('data-i18n') || (b.textContent||'').trim()).slice(0,28);
            try { b.click(); } catch(e){}
            await new Promise(function(r){ setTimeout(r, 50); });
            report.controls.push({ label: label, disabled: !!b.disabled,
                msg: log.msgs.slice(m0).join('|'), file: log.files.length > f0,
                dom: Math.abs(document.body.innerHTML.length - h0) });
        }
        var cbs = Array.prototype.slice.call(document.querySelectorAll('input[type=checkbox]'));
        report.checkboxes = { total: cbs.length, enabled: cbs.filter(function(c){ return !c.disabled; }).length };
        document.removeEventListener('click', stopNav, true);
        try { if (realSend) vAPI.messaging.send = realSend; } catch(e){}
        HTMLInputElement.prototype.click = realFileClick;
        window.confirm = realConfirm; window.alert = realAlert; window.open = realOpen;
        return JSON.stringify(report);
        """

        /// Read the background page's persisted errors/API map (written by mt-shim.js)
        /// and live-test the dashboard messaging channel from this page's world.
        private func probeBackground(_ w: WKWebView) {
            let js = """
            const api = (typeof browser !== 'undefined' ? browser : chrome);
            const stored = await api.storage.local.get(['mtBgErrs', 'mtBgApis']);
            let usType = 'no-vAPI';
            try {
                if (typeof vAPI !== 'undefined' && vAPI.messaging) {
                    const us = await vAPI.messaging.send('dashboard', { what: 'userSettings' });
                    usType = us === undefined ? 'undefined' : (us === null ? 'null' : typeof us);
                }
            } catch (e) { usType = 'threw: ' + e; }
            return JSON.stringify({ bgErrs: stored.mtBgErrs || [], bgApis: stored.mtBgApis || {}, userSettings: usType });
            """
            w.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): ExtLog.write("bgprobe \(v as? String ?? String(describing: v))")
                case .failure(let e): ExtLog.write("bgprobe FAILED \(e)")
                }
            }
            // Functional check: are the settings controls actually live?
            let uiProbe = """
            (function(){
              var cbs = document.querySelectorAll('input[type=checkbox]');
              var disabled = 0; cbs.forEach(function(c){ if(c.disabled || c.closest('.checkbox[disabled]')) disabled++; });
              var btns = Array.from(document.querySelectorAll('button, .push-button, a.push-button')).map(function(b){
                  return {t: (b.textContent||'').trim().slice(0,20), dis: !!b.disabled}; });
              return JSON.stringify({checkboxes: cbs.length, disabledCheckboxes: disabled, buttons: btns});
            })()
            """
            w.evaluateJavaScript(uiProbe) { r, _ in ExtLog.write("uiprobe \(r as? String ?? "?")") }
        }

        private func measure(_ w: WKWebView, tag: String) {
            let probe = """
            JSON.stringify({len: document.body ? document.body.innerText.length : -1,
                            kids: document.body ? document.body.children.length : -1,
                            state: document.readyState,
                            title: document.title,
                            bg: document.body ? getComputedStyle(document.body).backgroundColor : '',
                            ink: (function(){ var el = document.querySelector('label, h3, li, p, span');
                                              return el ? getComputedStyle(el).color : ''; })(),
                            iframes: Array.from(document.querySelectorAll('iframe')).map(function(f){
                                var doc = null; try { doc = f.contentDocument; } catch(e){}
                                return {src:(f.getAttribute('src')||''),
                                        w:f.clientWidth, h:f.clientHeight,
                                        inner: doc && doc.body ? doc.body.innerText.length : -1};
                            }),
                            errs: (window.__mtErrs||[]).slice(0,6)})
            """
            w.evaluateJavaScript(probe) { r, e in
                ExtLog.write("probe[\(tag)] \(r as? String ?? "eval-error: \(String(describing: e))")")
            }
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
            ExtLog.write("options didFail: \(e.localizedDescription)")
        }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            ExtLog.write("options didFailProvisional: \(e.localizedDescription)")
        }
    }
}

enum ExtLog {
    static func write(_ msg: String) { MTDebug.log("[extui] \(msg)") }
}

/// Sheet with a picker to switch between the two extensions' real settings pages.
struct ExtensionSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var which = "uBO"
    @State private var uboPane = "settings.html"

    /// uBO's dashboard.html hosts its panes in an iframe, and WebKit cancels the
    /// iframe's webkit-extension:// navigation (same policy that required the vended
    /// config — subframes get no exemption). The panes are standalone pages though,
    /// so we load each directly as the MAIN frame and provide the tab strip natively.
    private static let uboPanes: [(String, String)] = [
        ("Settings", "settings.html"),
        ("Filter lists", "3p-filters.html"),
        ("My filters", "1p-filters.html"),
        ("Trusted sites", "whitelist.html"),
        ("Support", "support.html"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Extension settings").font(.headline)
                Spacer()
                Picker("", selection: $which) {
                    Text("uBlock Origin").tag("uBO")
                    Text("SponsorBlock").tag("SponsorBlock")
                }
                .pickerStyle(.segmented).frame(width: 300).labelsHidden()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            if which == "uBO" {
                HStack(spacing: 8) {
                    Picker("", selection: $uboPane) {
                        ForEach(ExtensionSettingsSheet.uboPanes, id: \.1) { name, file in
                            Text(name).tag(file)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            content
        }
        .frame(width: 960, height: 700)
    }

    /// The page to load: uBO panes directly (dashboard iframe is a dead end under
    /// WebKit); SponsorBlock's own options page as declared.
    private func pageURL() -> URL? {
        if #available(macOS 15.4, *) {
            guard let base = UBlockLoader.shared.settingsURL(for: which) else { return nil }
            if which == "uBO" {
                return base.deletingLastPathComponent().appendingPathComponent(uboPane)
            }
            return base
        }
        return nil
    }

    @ViewBuilder private var content: some View {
        if #available(macOS 15.4, *),
           let controller = UBlockLoader.shared.controller,
           let extContext = UBlockLoader.shared.contexts[which],
           let url = pageURL() {
            ExtensionSettingsWeb(url: url, controller: controller, extContext: extContext,
                                 readableTextFix: which == "uBO")
                .id(which + uboPane)   // rebuild the web view when switching pages
        } else {
            VStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Extension settings unavailable")
                Text("The real uBlock Origin Lite / SponsorBlock require macOS 15.4+ and load a moment after launch.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
        }
    }
}
