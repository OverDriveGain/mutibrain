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

    static func install() {
        sigFilePathC = sigFile.cString(using: .utf8) ?? []

        NSSetUncaughtExceptionHandler { e in
            let frames = e.callStackSymbols.prefix(5)
                .map { $0.split(separator: " ").dropFirst(3).joined(separator: ".") }
                .joined(separator: "|")
            CrashReporter.record("nsexc-\(e.name.rawValue)-\(e.reason ?? "")-@-\(frames)")
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                CrashReporter.writeSignalMarker(s)
                // restore + re-raise so the process still dies normally
                signal(s, SIG_DFL)
                raise(s)
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

    /// Call once at launch, after the beacon channel exists.
    static func reportIfCrashed() {
        let nsexc = UserDefaults.standard.string(forKey: key)
        if let r = nsexc {
            UserDefaults.standard.removeObject(forKey: key)
            GadkVoice.beacon("crash-\(r)")
        }
        if let s = try? String(contentsOfFile: sigFile, encoding: .utf8), !s.isEmpty {
            try? FileManager.default.removeItem(atPath: sigFile)
            // An NSException that reaches the top also aborts (SIGABRT) — the
            // nsexc beacon above already carries the detail, so only report a
            // bare signal when there was no exception record.
            if nsexc == nil { GadkVoice.beacon("crash-\(s)") }
        }
    }
}
