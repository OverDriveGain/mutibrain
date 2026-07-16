import Foundation

/// Server-driven Chat tab config.
///
/// The voice server's /config endpoint (already gated by the subscriber's own
/// voice token) may carry a `chatUrl` — the tokenized MyMu agent-view link for
/// this subscriber's Chat tab (served from agents/<name>/chat.url on the
/// server). On launch/foreground we fetch it and, when present and different,
/// overwrite the stored chatURL. Rotating or fixing a chat token is therefore
/// a server-side file edit — no Settings paste, no rebuild, no phone touch.
///
/// The manual Settings field still works: the server value only wins when the
/// server actually serves one, and the beacon in the journal shows when it did.
enum ChatURLSync {
    static func run() {
        let d = UserDefaults(suiteName: SharedConfig.appGroup) ?? .standard
        let stored = d.string(forKey: "gadkURL")
        let gadk = (stored?.isEmpty == false ? stored! : SharedConfig.defaultGadk)
        guard var comps = URLComponents(string: gadk),
              let items = comps.queryItems,
              let app = items.first(where: { $0.name == "app" })?.value, !app.isEmpty,
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty,
              !token.contains("__")   // unfilled build placeholder
        else { return }
        comps.path = "/config"
        comps.fragment = nil
        comps.queryItems = [URLQueryItem(name: "app", value: app),
                            URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chat = obj["chatUrl"] as? String, !chat.isEmpty,
                  URL(string: chat) != nil
            else { return }
            DispatchQueue.main.async {
                if d.string(forKey: "chatURL") != chat {
                    d.set(chat, forKey: "chatURL")   // @AppStorage views reload via .id(chatURL)
                    GadkVoice.beacon("chaturl-synced")
                }
            }
        }.resume()
    }
}
