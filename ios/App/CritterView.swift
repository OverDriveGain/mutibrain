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
        web.load(URLRequest(url: comps.url!))
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
        }
    }
}
