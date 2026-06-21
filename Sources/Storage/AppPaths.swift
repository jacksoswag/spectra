import Foundation

/// Resolves and lazily creates the on-disk locations Spectra persists to, under
/// `~/Library/Application Support/Spectra`.
enum AppPaths {
    static let folderName = "Spectra"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    static var presetsDirectory: URL { supportDirectory.appendingPathComponent("Presets", isDirectory: true) }
    static var shadersDirectory: URL { supportDirectory.appendingPathComponent("Shaders", isDirectory: true) }
    static var composedDirectory: URL { supportDirectory.appendingPathComponent("Effects", isDirectory: true) }
    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var stateFile: URL { supportDirectory.appendingPathComponent("state.json") }
    static var licenseFile: URL { supportDirectory.appendingPathComponent("license.json") }

    /// Create the directory tree if needed. Safe to call repeatedly.
    static func ensureDirectories() {
        for directory in [supportDirectory, presetsDirectory, shadersDirectory, composedDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
