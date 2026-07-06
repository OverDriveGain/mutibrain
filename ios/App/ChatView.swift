import SwiftUI
import WebKit

/// The MyMu (CCUI) chat — text conversations with the fleet agents
/// (special-agent etc.), one conversation per agent. This embeds the live
/// instance rather than cloning its UI; login persists in the webview's
/// default (persistent) data store.
struct ChatView: UIViewRepresentable {
    @AppStorage("chatURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var chatURL: String = SharedConfig.defaultChat

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()          // keep the MyMu login session
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.keyboardDismissMode = .interactive
        if let url = URL(string: chatURL) {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
