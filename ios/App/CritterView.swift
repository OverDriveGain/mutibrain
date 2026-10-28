import SwiftUI
import WebKit

/// Posted when the web massam panel asks the app to open the native screen
/// capture controls (the standard broadcast picker lives natively; a web tile
/// can't host it, so the "Screen" massam bridges through here). PetView listens.
extension Notification.Name {
    static let mymuShowScreenpipe = Notification.Name("mymuShowScreenpipe")
    /// The embed's keyboard composer opened/closed (userInfo["open"]: Bool) —
    /// PetView hides the native mic cluster while the user is writing.
    static let mymuComposing = Notification.Name("mymuComposing")
    /// The Music massam asks the NATIVE player to play a queue
    /// (userInfo["songs"]: [[String: Any]], ["startAt"]: Int) …
    static let mymuPlaySongs = Notification.Name("mymuPlaySongs")
    /// … or to control what is playing (userInfo["action"]: pause|resume|next|previous).
    static let mymuMusicControl = Notification.Name("mymuMusicControl")
}

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

    /// One-shot trick (jump/spin/dance/shake) or shape — `move` must already be
    /// sanitized. `duration` (seconds, from the agent's perform_move tool) holds
    /// the move/shape on screen that long; nil uses the embed's natural default.
    func perform(_ move: String, duration: Double? = nil) {
        let opts: String
        if let d = duration, d > 0 {
            opts = String(format: ", { duration: %.2f }", d)
        } else {
            opts = ""
        }
        let js = "window.critter && window.critter.perform && window.critter.perform('\(move)'\(opts))"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Live audio level 0…1 into the avatar (mic while the user talks,
    /// playback while the assistant answers). Throttled: publishers fire at
    /// audio rate, the JS bridge only needs ~30Hz and visible deltas.
    private var lastLevelAt: CFAbsoluteTime = 0
    private var lastLevel: Float = -1
    func setLevel(_ v: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelAt >= 1.0 / 30.0,
              abs(v - lastLevel) > 0.015 || (v == 0 && lastLevel != 0) else { return }
        lastLevelAt = now; lastLevel = v
        let js = String(format: "window.critter && window.critter.setLevel && window.critter.setLevel(%.3f)", v)
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: stage composition — the chat drawer takes the lower screen
    // The webview stays full-bleed; the EMBED shifts/scales its canvas layer
    // (a GPU transform, no resize) so the swarm re-centres in the space the
    // drawer leaves, and raises its overlay controls by `inset` (the peek
    // bar). Throttled to ~30Hz with a trailing flush so the last value of a
    // drag always lands; re-applied after a page (re)load.
    private var stageJS = ""
    /// The last stage sent, re-asserted after a (re)load; `stageJS` is the queue.
    private var lastStageJS = ""
    private var stageInFlight = false
    func setStage(shift: CGFloat, scale: CGFloat, inset: CGFloat, dragging: Bool) {
        stageJS = String(format: "window.critter && window.critter.setStage && window.critter.setStage({shift:%.1f,scale:%.3f,inset:%.0f,dragging:%@})",
                         Double(shift), Double(scale), Double(inset), dragging ? "true" : "false")
        // Coalesced, not throttled: while one call is in the webview's queue
        // only the LATEST stage waits behind it, so the swarm tracks the finger
        // at whatever rate the web process keeps up with (was a fixed 30Hz).
        if !stageInFlight { flushStage() }
    }
    /// App back in the foreground: WebKit throttles/suspends a backgrounded
    /// page, so state and stage pushed meanwhile may never have landed —
    /// re-send everything the page should be showing.
    func resync() {
        apply()
        reassertStage()
        pushCapabilities()
        refreshPending()
    }
    fileprivate func reassertStage() {
        if stageJS.isEmpty { stageJS = lastStageJS }
        stageInFlight = false
        flushStage()
    }
    fileprivate func flushStage() {
        guard !stageJS.isEmpty, let webView else { return }
        let js = stageJS
        lastStageJS = js
        stageJS = ""
        stageInFlight = true
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            guard let self else { return }
            self.stageInFlight = false
            if !self.stageJS.isEmpty { self.flushStage() }
        }
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
        var tick = 0
        feedTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshPending()
            tick += 1
            // The suggestion deck grows with the user's history — re-pull it
            // every minute so new "want to follow up on…?" items appear.
            if tick % 12 == 0 { self?.pushCapabilities() }
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
        // JS -> native bridge: the "Screen" massam posts mymuBroadcast to pop the
        // native broadcast picker (the standard button can't live inside the web
        // panel). Registered on the shared content controller before the webview.
        cfg.userContentController.add(context.coordinator, name: "mymuBroadcast")
        // 2026-10-23: the keyboard composer (hide the mic while writing) and
        // the Music massam (play through the native player, same queue the
        // voice tools fill — lock screen / background / AirPlay for free).
        cfg.userContentController.add(context.coordinator, name: "mymuCompose")
        cfg.userContentController.add(context.coordinator, name: "mymuMusic")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        // Fill under the safe areas so the page (not the webview's bg) reaches
        // the notch + home-indicator edges, and paint that bg near-black instead
        // of the old purple — otherwise the purple showed at top & bottom and the
        // glass tab bar sampled it. (Pairs with viewport-fit=cover in the embed.)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.02, green: 0.024, blue: 0.031, alpha: 1) // #050608
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator   // target=_blank (file downloads) -> Safari
        controller.webView = web

        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        comps.path = "/static/critter/embed.html"
        comps.query = nil
        // Pass the subscriber identity to the embed in the URL FRAGMENT (never
        // sent to the server/logs): the task panel inside the page uses it to
        // call /panel + /panel/run. Values come from the configured gadk URL.
        let q = URLComponents(url: SharedConfig.load().gadkURL,
                              resolvingAgainstBaseURL: false)?.queryItems ?? []
        let app = q.first { $0.name == "app" }?.value ?? ""
        let token = q.first { $0.name == "token" }?.value ?? ""
        // nochat=1 (2026-10-24): the app has its OWN chat — the native MyMu
        // conversation in the drawer under the swarm — so the embed keeps its
        // web keyboard composer off. One chat, not two.
        if !app.isEmpty && !token.isEmpty {
            comps.fragment = "app=\(app)&token=\(token)&nochat=1"
        } else {
            comps.fragment = "nochat=1"
        }
        // Always refetch the page itself — WKWebView happily serves a stale
        // embed.html for days otherwise (the hashed JS assets can still cache).
        web.load(URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    /// Re-assert the current state once the page finishes loading, so a state set
    /// before load (or after a reload) isn't lost.
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let controller: CritterController
        init(controller: CritterController) { self.controller = controller }

        /// JS -> native. The web "Screen" massam posts here to open the native
        /// screen-capture sheet (standard broadcast picker + mic). PetView, which
        /// owns the presentation state, observes the notification.
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "mymuBroadcast":
                // the home's Screen button: straight to iOS's broadcast sheet
                // (`present`); anything else opens the full Screenpipe page
                if (message.body as? [String: Any])?["action"] as? String == "present" {
                    BroadcastLauncher.present()
                } else {
                    NotificationCenter.default.post(name: .mymuShowScreenpipe, object: nil)
                }
            case "mymuCompose":
                let open = (message.body as? [String: Any])?["open"] as? Bool ?? false
                NotificationCenter.default.post(name: .mymuComposing, object: nil,
                                                userInfo: ["open": open])
            case "mymuMusic":
                guard let body = message.body as? [String: Any],
                      let action = body["action"] as? String else { return }
                if action == "play", let songs = body["songs"] as? [[String: Any]], !songs.isEmpty {
                    NotificationCenter.default.post(name: .mymuPlaySongs, object: nil,
                                                    userInfo: ["songs": songs,
                                                               "startAt": body["startAt"] as? Int ?? 0])
                } else {
                    NotificationCenter.default.post(name: .mymuMusicControl, object: nil,
                                                    userInfo: ["action": action])
                }
            default:
                break
            }
        }

        /// The Files box opens downloads with target=_blank; a bare WKWebView
        /// silently drops those. Hand them to Safari (which previews/saves any
        /// file type) and keep the critter page where it is.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url)
            }
            return nil
        }
        /// iOS kills a backgrounded page's web process to reclaim memory; the
        /// webview then sits frozen on its last frame (an idle-looking swarm
        /// while she talks). Reload — didFinish re-asserts state + stage.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            GadkVoice.beacon("embed-process-terminated")
            webView.reload()
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.apply()
            // Re-push feed data after any (re)load — the fresh page starts empty.
            controller.pushCapabilities()
            controller.refreshPending()
            // The stage (drawer composition) is page state — re-assert it once
            // the module has set window.critter (async after load).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [controller] in controller.reassertStage() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [controller] in controller.reassertStage() }
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
