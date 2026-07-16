import Foundation

/// The only crash telemetry we have without device tooling: persist the fatal
/// reason at death, beacon it on the NEXT launch (`crash-…` in the server
/// journal). Uncaught NSExceptions get name+reason+top frames; fatal signals
/// get the signal number via an async-signal-safe write(2) to a fixed file.
enum CrashReporter {
    private static let key = "lastCrashReason"

    /// Written by the signal handler with plain write(2) — UserDefaults is not
    /// async-signal-safe. Read + cleared on the next launch.
    private static let sigFile = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("crash-signal.txt").path

    private static var sigFilePathC: [CChar] = []

    /// Alive-stamp: written every 10 s. iOS's watchdog and the jetsam (OOM)
    /// killer use SIGKILL, which NO in-process handler can observe — the
    /// 2026-07-15 music deaths left zero trace. A fresh stamp with no crash
    /// marker on the next launch is the fingerprint of exactly that.
    private static let aliveFile = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("alive-stamp.txt")
    private static var aliveTimer: Timer?

    static func install() {
        sigFilePathC = sigFile.cString(using: .utf8) ?? []

        aliveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            try? String(Date().timeIntervalSince1970)
                .write(to: aliveFile, atomically: true, encoding: .utf8)
        }

        NSSetUncaughtExceptionHandler { e in
            let frames = e.callStackSymbols.prefix(5)
                .map { $0.split(separator: " ").dropFirst(3).joined(separator: ".") }
                .joined(separator: "|")
            CrashReporter.record("nsexc-\(e.name.rawValue)-\(e.reason ?? "")-@-\(frames)")
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                CrashReporter.writeSignalMarker(s)
                signal(s, SIG_DFL)
                // For hardware traps (SIGTRAP/SEGV/BUS/ILL/FPE), RETURN: the
                // faulting instruction re-executes under SIG_DFL and iOS
                // writes a TRUE crash report with the real stack. Re-raising
                // (the old behavior) produced .ips files whose every thread
                // looked idle — it masked the Int16-abs mic crash for a day.
                // SIGABRT doesn't re-execute; re-raise that one.
                if s == SIGABRT { raise(s) }
            }
        }
    }

    static func record(_ reason: String) {
        UserDefaults.standard.set(String(reason.prefix(800)), forKey: key)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    /// async-signal-safe: open/write/close only.
    private static func writeSignalMarker(_ sig: Int32) {
        guard !sigFilePathC.isEmpty else { return }
        let fd = open(sigFilePathC, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        var msg = "signal-\(sig)"
        _ = msg.withUTF8 { buf in write(fd, buf.baseAddress, buf.count) }
        close(fd)
    }

    /// Call once at launch, after the beacon channel exists. The breadcrumb
    /// trail on disk is still the PREVIOUS run's at this moment — exactly the
    /// death context — so capture it before this run writes much to it.
    static func reportIfCrashed() {
        let deathTrail = Breadcrumbs.tail()
        let nsexc = UserDefaults.standard.string(forKey: key)
        if let r = nsexc {
            UserDefaults.standard.removeObject(forKey: key)
            GadkVoice.beacon("crash-\(r)")
            ReportClient.submit(kind: "crash", reason: r, breadcrumbs: deathTrail)
        }
        var sawSignal = false
        if let s = try? String(contentsOfFile: sigFile, encoding: .utf8), !s.isEmpty {
            try? FileManager.default.removeItem(atPath: sigFile)
            sawSignal = true
            // An NSException that reaches the top also aborts (SIGABRT) — the
            // nsexc report above already carries the detail, so only report a
            // bare signal when there was no exception record.
            if nsexc == nil {
                GadkVoice.beacon("crash-\(s)")
                ReportClient.submit(kind: "crash", reason: s, breadcrumbs: deathTrail)
            }
        }
        // No crash record but a stamp exists -> the previous run ended
        // without any catchable signal: SIGKILL-class (watchdog / jetsam) or
        // a user swipe-kill. The stamp age says how long ago it died. Only
        // FRESH stamps become reports (an old one is routine suspended-app
        // cleanup by iOS, not a death worth a report).
        if nsexc == nil, !sawSignal,
           let s = try? String(contentsOf: aliveFile, encoding: .utf8),
           let last = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let age = Int(Date().timeIntervalSince1970 - last)
            GadkVoice.beacon("killed-uncatchable-lastalive-\(age)s-ago")
            if age < 300 {
                ReportClient.submit(kind: "crash",
                                    reason: "killed-uncatchable (watchdog/jetsam/swipe) "
                                        + "last alive \(age)s before relaunch",
                                    breadcrumbs: deathTrail)
            }
        }
        try? FileManager.default.removeItem(at: aliveFile)
    }
}
