import Foundation
import QuartzCore

/// TEMPORARY file-based diagnostics for the Space-switch freeze and the Dock-cursor bug.
/// The overlay is uncapturable and unified logging is awkward to pull, so this appends
/// throttled, human-readable lines to two files under /tmp that the owner can paste back.
/// Remove this file and its call sites once both bugs are diagnosed.
enum Diag {
    /// Master switch. Flip to false (or delete the call sites) to silence everything.
    static let enabled = true

    private static let queue = DispatchQueue(label: "com.spectra.diag")
    private static let start = CACurrentMediaTime()
    private static let freezeURL = URL(fileURLWithPath: "/tmp/spectra-freeze-diag.log")
    private static let cursorURL = URL(fileURLWithPath: "/tmp/spectra-cursor-diag.log")

    static func freeze(_ line: @autoclosure () -> String) { append(line(), to: freezeURL) }
    static func cursor(_ line: @autoclosure () -> String) { append(line(), to: cursorURL) }

    /// Mark a new launch in both logs. APPENDS a header rather than truncating, so a freeze that
    /// forces a relaunch (or a machine restart with auto-launch) doesn't erase the previous
    /// session's evidence — which is exactly what happened once already.
    static func reset() {
        guard enabled else { return }
        append("=== spectra diag, launched ===", to: freezeURL)
        append("=== spectra diag, launched ===", to: cursorURL)
    }

    private static func append(_ line: String, to url: URL) {
        guard enabled else { return }
        let t = CACurrentMediaTime() - start
        let stamped = String(format: "%8.2f  %@\n", t, line)
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? stamped.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
