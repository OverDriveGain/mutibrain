import Foundation
import UIKit

/// Single source for the build tag carried by beacons and reports.
enum AppBuild {
    static let tag = "v12-reports"
}

/// Rolling event trail, mirrored to disk so it SURVIVES a crash — every
/// report carries the last minute(s) of app history (the exact timeline we
/// used to reconstruct by hand from server journals).
enum Breadcrumbs {
    private static let q = DispatchQueue(label: "crumbs", qos: .utility)
    private static let file = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("breadcrumbs.log")
    private static let maxBytes = 96 * 1024

    static func add(_ msg: String) {
        q.async {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            let line = "\(df.string(from: Date())) \(msg)\n"
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
            trimIfNeeded()
        }
    }

    /// Last `count` lines (crash context: what happened right before death).
    static func tail(_ count: Int = 80) -> [String] {
        q.sync {
            guard let s = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return s.split(separator: "\n").suffix(count).map(String.init)
        }
    }

    private static func trimIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int, size > maxBytes,
              let s = try? String(contentsOf: file, encoding: .utf8) else { return }
        let kept = s.split(separator: "\n").suffix(400).joined(separator: "\n") + "\n"
        try? kept.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Sends structured crash/bug/exception reports to the voice server's
/// POST /report (authenticated with the SUBSCRIBER's own token, so every
/// report is attributed). Disk-queued: a report that can't be sent now is
/// retried on every launch/foreground until the server confirms.
enum ReportClient {
    private static let pendingDir = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pending-reports", isDirectory: true)

    static var deviceModel: String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// Build + enqueue + attempt one report. `extra` merges into the payload.
    static func submit(kind: String, text: String? = nil, reason: String? = nil,
                       breadcrumbs: [String]? = nil,
                       completion: ((Bool) -> Void)? = nil) {
        var payload: [String: Any] = [
            "kind": kind,
            "build": AppBuild.tag,
            "device": deviceModel,
            "os": UIDevice.current.systemVersion,
            "at": Date().timeIntervalSince1970,
            "breadcrumbs": breadcrumbs ?? Breadcrumbs.tail(),
        ]
        if let text { payload["text"] = text }
        if let reason { payload["reason"] = reason }
        enqueue(payload)
        flush(completion: completion)
    }

    private static func enqueue(_ payload: [String: Any]) {
        try? FileManager.default.createDirectory(at: pendingDir,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: pendingDir.appendingPathComponent(UUID().uuidString + ".json"))
        }
    }

    /// Try to deliver everything queued. Called at launch, on foreground, and
    /// right after a new report is filed.
    static func flush(completion: ((Bool) -> Void)? = nil) {
        let t = GadkVoice.feedTarget()
        guard !t.token.isEmpty else { completion?(false); return }  // pre-login: stay queued
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: pendingDir, includingPropertiesForKeys: nil), !files.isEmpty else {
            completion?(true); return
        }
        var comps = URLComponents(url: t.origin.appendingPathComponent("report"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "app", value: t.app),
                            .init(name: "token", value: t.token)]
        let url = comps.url!

        var remaining = files.count
        var allOk = true
        for f in files {
            guard let body = try? Data(contentsOf: f) else { remaining -= 1; continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                if ok {
                    try? FileManager.default.removeItem(at: f)
                } else {
                    allOk = false
                }
                remaining -= 1
                if remaining <= 0 { DispatchQueue.main.async { completion?(allOk) } }
            }.resume()
        }
    }
}
