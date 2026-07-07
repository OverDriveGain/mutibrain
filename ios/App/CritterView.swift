import SwiftUI
import WebKit

/// The critter — mymu-voice's SDF blend-shell character, rendered by the server's
/// public embed page (static/critter/embed.html) inside a WKWebView.
///
/// VISUALS ONLY. The webview never touches audio — voice is native (GadkVoice),
/// which is exactly why the old in-webview voice was replaced. The app drives the
/// character over a one-way JS bridge:
///
///     window.critter.setState('idle' | 'listening' | 'talking')
///
/// The embed URL is derived from the configured gadk URL's origin; the page is
/// public (no token), tap-to-poke is handled inside the page itself.
final class CritterController: ObservableObject {
    fileprivate weak var webView: WKWebView?
    private var pendingState = "idle"
    private var feedTimer: Timer?
    private var feed: (origin: URL, app: String, token: String)?

    func setState(_ state: String) {
        pendingState = state
        apply()
    }

    fileprivate func apply() {
        let js = "window.critter && window.critter.setState('\(pendingState)')"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// One-shot trick (jump/spin/dance/shake) — `move` must already be sanitized.
    func perform(_ move: String) {
        let js = "window.critter && window.critter.perform && window.critter.perform('\(move)')"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: server feeds — pending brain tasks + capability cards
    // The embed is render-only; the app is the data plane. We poll GET /pending
    // (what was handed to the brain, what's still awaited) and push it into the
    // webview; capabilities are fetched once and popped as idle hint bubbles.

    func startFeeds(origin: URL, app: String, token: String) {
        guard !app.isEmpty, !token.isEmpty else { return }
        feed = (origin, app, token)
        pushCapabilities()
        refreshPending()
        feedTimer?.invalidate()
        feedTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshPending()
        }
    }

    func stopFeeds() {
        feedTimer?.invalidate()
        feedTimer = nil
    }

    fileprivate func pushCapabilities() { pushFeed(path: "capabilities", key: "capabilities", fn: "setCapabilities") }
    func refreshPending() { pushFeed(path: "pending", key: "pending", fn: "setPending") }

    private func pushFeed(path: String, key: String, fn: String) {
        guard let feed else { return }
        var c = URLComponents(url: feed.origin.appendingPathComponent(path),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "app", value: feed.app), .init(name: "token", value: feed.token)]
        guard let url = c.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj[key],
                  let payload = try? JSONSerialization.data(withJSONObject: arr),
                  let json = String(data: payload, encoding: .utf8) else { return }
            // JSON is a valid JS literal except U+2028/9, which break evaluateJavaScript
            let safe = json
                .replacingOccurrences(of: "\u{2028}", with: " ")
                .replacingOccurrences(of: "\u{2029}", with: " ")
            DispatchQueue.main.async {
                self?.webView?.evaluateJavaScript(
                    "window.critter && window.critter.\(fn) && window.critter.\(fn)(\(safe))",
                    completionHandler: nil)
            }
        }.resume()
    }
}

struct CritterView: UIViewRepresentable {
    @ObservedObject var controller: CritterController
    /// e.g. https://agent.kaxtus.com — the gadk origin; /static/critter/embed.html is appended.
    let origin: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.094, green: 0.071, blue: 0.18, alpha: 1) // #18122e
        web.navigationDelegate = context.coordinator
        controller.webView = web

        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        comps.path = "/static/critter/embed.html"
        comps.query = nil
        // Always refetch the page itself — WKWebView happily serves a stale
        // embed.html for days otherwise (the hashed JS assets can still cache).
        web.load(URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    /// Re-assert the current state once the page finishes loading, so a state set
    /// before load (or after a reload) isn't lost.
    final class Coordinator: NSObject, WKNavigationDelegate {
        let controller: CritterController
        init(controller: CritterController) { self.controller = controller }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.apply()
            // Re-push feed data after any (re)load — the fresh page starts empty.
            controller.pushCapabilities()
            controller.refreshPending()
            // Report which embed the webview actually runs (cache diagnosis).
            // Delayed: the page's module script sets window.critter async.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak webView] in
                webView?.evaluateJavaScript(
                    "window.critter && window.critter.moves ? 'moves:' + window.critter.moves.join('+') : 'OLD-EMBED'"
                ) { result, _ in
                    GadkVoice.beacon("embed-\(result as? String ?? "no-critter-api")")
                }
            }
        }
    }
}
