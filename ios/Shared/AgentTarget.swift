import Foundation

/// Where + who to talk to on the agent server (agent.kaxtus.com), parsed from the
/// configured gadk URL in the shared App Group store — the SAME parse
/// `GadkVoice.Target` does, but living in Shared/ so the OpenerControl widget
/// extension (which can't see App/GadkVoice.swift) can reach the agent too.
///
/// The gadk URL is the full tokenized voice URL, e.g.
/// `https://agent.kaxtus.com/voice?app=manar&token=…`; we keep only its
/// scheme+host+port as the origin and pull `app`/`token` from the query.
extension SharedConfig {
    struct AgentTarget {
        let origin: URL      // https://agent.kaxtus.com
        let app: String      // manar
        let token: String    // subscriber token ("" or contains "__" => not logged in)

        var loggedIn: Bool { !token.isEmpty && !token.contains("__") }

        /// Build an authed GET URL for a server path, e.g. "screen/opener".
        func url(path: String, extra: [URLQueryItem] = []) -> URL? {
            var comps = URLComponents(url: origin.appendingPathComponent(path),
                                      resolvingAgainstBaseURL: false)
            comps?.queryItems = [.init(name: "app", value: app),
                                 .init(name: "token", value: token)] + extra
            return comps?.url
        }
    }

    static func agentTarget() -> AgentTarget {
        let cfg = load()
        let url = URL(string: cfg.gadk) ?? URL(string: defaultGadk)!
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let app = q.first { $0.name == "app" }?.value ?? "manar"
        let token = q.first { $0.name == "token" }?.value ?? ""
        var o = URLComponents()
        o.scheme = url.scheme ?? "https"
        o.host = url.host
        o.port = url.port
        return AgentTarget(origin: o.url ?? url, app: app, token: token)
    }
}
