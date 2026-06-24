import SwiftUI
import WebKit

/// Shared state the pet reacts to while a voice session is live.
final class VoiceState: ObservableObject {
    @Published var active = false        // mic session running
    @Published var answering = false     // assistant is currently speaking
    @Published var caption = ""          // latest words the assistant is saying
}

/// The "Talk to me" control. It hosts the gadk voice page INLINE (no popup),
/// stripped by injected CSS down to just its big button so it reads as a native
/// button. Tapping it is a real user gesture, so the in-page getUserMedia mic
/// request works. Injected JS forwards the assistant's streaming captions + state
/// to native, which the pet turns into a speech bubble + happy mood.
struct VoiceBridge: UIViewRepresentable {
    let url: URL
    @ObservedObject var state: VoiceState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "petbridge")
        controller.addUserScript(WKUserScript(source: Self.bridgeJS,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        let state: VoiceState
        init(state: VoiceState) { self.state = state }

        // auto-grant the in-page mic permission
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }

        func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard let d = msg.body as? [String: Any], let type = d["type"] as? String else { return }
            DispatchQueue.main.async {
                switch type {
                case "rec":
                    self.state.active = (d["on"] as? Bool) ?? false
                    if !self.state.active { self.state.caption = ""; self.state.answering = false }
                case "status":
                    let t = (d["text"] as? String ?? "")
                    self.state.answering = t.contains("Answering")
                case "caption":
                    if (d["who"] as? String) == "agent" {
                        var t = d["text"] as? String ?? ""
                        if let r = t.range(of: "Agent: ") { t.removeSubrange(r) }
                        self.state.caption = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                default: break
                }
            }
        }
    }

    /// Strip the gadk page to its button, relabel it, and forward state/captions.
    private static let bridgeJS = """
    (function(){
      var css = "html,body{background:transparent!important;margin:0;height:100%;overflow:hidden}"
        + "h1,.status,.meter,#log,.hint{display:none!important}"
        + "body{display:block!important}"
        + "#talkBtn{position:fixed!important;inset:0!important;width:100%!important;height:100%!important;"
        + "border-radius:20px!important;font-size:19px!important;box-shadow:none!important;"
        + "background:linear-gradient(160deg,#5b54e0,#6a5cff)!important}"
        + "#talkBtn.recording{background:linear-gradient(160deg,#ff5b6e,#ff3b5c)!important;animation:none!important}";
      var s=document.createElement('style'); s.textContent=css; document.head.appendChild(s);
      function post(o){ try{ window.webkit.messageHandlers.petbridge.postMessage(o); }catch(e){} }
      var btn=document.getElementById('talkBtn');
      function relabel(){ if(btn){ btn.textContent = btn.classList.contains('recording') ? 'Listening… tap to stop' : 'Talk to me'; } }
      relabel();
      if(btn){ new MutationObserver(function(){ relabel(); post({type:'rec', on: btn.classList.contains('recording')}); })
        .observe(btn,{attributes:true,attributeFilter:['class']}); }
      var st=document.getElementById('status');
      if(st){ new MutationObserver(function(){ post({type:'status', text: st.textContent||''}); })
        .observe(st,{childList:true,subtree:true,characterData:true}); }
      var log=document.getElementById('log');
      if(log){ new MutationObserver(function(){
          var lines=log.querySelectorAll('.line'); if(!lines.length) return;
          var last=lines[lines.length-1];
          post({type:'caption', who: last.classList.contains('you')?'you':'agent', text: last.textContent||''});
        }).observe(log,{childList:true,subtree:true,characterData:true}); }
    })();
    """
}
