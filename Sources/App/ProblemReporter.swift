import AppKit

/// No-dependency "Report a Problem": opens a prefilled mail draft with app and
/// system diagnostics, and reveals the most recent Spectra crash report in Finder
/// so the user can attach it (a `mailto:` URL can't carry attachments). No network
/// call, no account, no bundled crash-reporting SDK.
enum ProblemReporter {
    /// Support inbox. TODO(Phase 2): finalise with the real support address once the
    /// domain/landing/support setup is decided.
    static let supportEmail = "support@spectra.app"

    static func report() {
        revealLatestCrashReport()
        let subject = "Spectra problem report (\(AppInfo.versionWithBuild))"
        var components = URLComponents(string: "mailto:\(supportEmail)")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: diagnosticSummary()),
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    private static func diagnosticSummary() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return """
        Describe the problem here:


        ---
        Spectra \(AppInfo.versionWithBuild)
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        Hardware: \(hardwareModel())
        (If a crash report opened in Finder, please attach it to this email.)
        """
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    /// Reveal the most recent Spectra crash report in Finder, if one exists.
    private static func revealLatestCrashReport() {
        let dir = ("~/Library/Logs/DiagnosticReports" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let latest = entries
            .filter { $0.hasPrefix("Spectra") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
            .compactMap { name -> (path: String, date: Date)? in
                let path = "\(dir)/\(name)"
                guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
                return (path, date)
            }
            .max { $0.date < $1.date }
        if let latest {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: latest.path)])
        }
    }
}
