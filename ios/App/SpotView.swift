import SwiftUI
import WebKit

/// The Spot — a shared little garden world (mymu-voice `/spot`) rendered by the
/// server page (static/spot.html) inside a WKWebView. Subscribers whose profile
/// shares the same spot id are in the SAME garden and see each other's critters;
/// "walk to <name>" (voice) strolls yours over on every screen in the spot.
///
/// VISUALS ONLY, like CritterView — voice stays native (GadkVoice). Unlike the
/// public critter embed, `/spot` is TOKEN-GATED (it reads presence per
/// subscriber), so identity rides in the URL QUERY (app+token), which the page
/// reads from location.search for its own /spot/snapshot + /spot/state polls.
struct SpotView: UIViewRepresentable {
    /// e.g. https://agent.kaxtus.com — the gadk origin; /spot is appended.
    let origin: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.039, green: 0.043, blue: 0.086, alpha: 1) // #0a0b16
        web.load(spotRequest())
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    /// `<origin>/spot?app=…&token=…` — identity pulled from the configured gadk URL.
    private func spotRequest() -> URLRequest {
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        comps.path = "/spot"
        let q = URLComponents(url: SharedConfig.load().gadkURL,
                              resolvingAgainstBaseURL: false)?.queryItems ?? []
        let app = q.first { $0.name == "app" }?.value ?? ""
        let token = q.first { $0.name == "token" }?.value ?? ""
        comps.queryItems = [.init(name: "app", value: app),
                            .init(name: "token", value: token)]
        // Always refetch: WKWebView will otherwise serve a stale spot.html.
        return URLRequest(url: comps.url!,
                          cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    }
}
