import Foundation

/// Resolves and lazily creates the on-disk locations Spectra persists to, under
/// `~/Library/Application Support/Spectra`.
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Spectra", isDirectory: true)
    }

    static var presetsDirectory: URL { supportDirectory.appendingPathComponent("Presets", isDirectory: true) }
    static var shadersDirectory: URL { supportDirectory.appendingPathComponent("Shaders", isDirectory: true) }
    static var composedDirectory: URL { supportDirectory.appendingPathComponent("Effects", isDirectory: true) }
    /// User-supplied images copied in for custom-cursor sprites; the param stores just the filename.
    static var cursorsDirectory: URL { supportDirectory.appendingPathComponent("Cursors", isDirectory: true) }
    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var stateFile: URL { supportDirectory.appendingPathComponent("state.json") }
    static var licenseFile: URL { supportDirectory.appendingPathComponent("license.json") }
    /// Owner/developer override (DEBUG builds only — ignored in release; see
    /// `LicenseManager.developerUnlock`): if this hidden file exists, licensing reports
    /// the full (licensed) tier regardless of any key. Create it to unlock a local build
    /// without the purchase flow; delete it to test the gated free tier.
    static var developerUnlockFile: URL { supportDirectory.appendingPathComponent(".developer-unlock") }

    /// Reduce an arbitrary identifier to a single safe path component, so a crafted
    /// import id (e.g. `"../../tmp/evil"` from an untrusted `.spectra`/`.metal` file) can't
    /// escape its store directory and write or delete an arbitrary user file. Strips path
    /// separators and any `..` traversal; never returns empty.
    static func safeComponent(_ id: String) -> String {
        let cleaned = id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    /// Create the directory tree if needed. Safe to call repeatedly.
    static func ensureDirectories() {
        for directory in [supportDirectory, presetsDirectory, shadersDirectory, composedDirectory, cursorsDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
