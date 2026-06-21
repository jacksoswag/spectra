import Foundation

/// App metadata read from the bundle, so the version lives in exactly one place
/// (`project.yml`'s `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, baked into
/// Info.plist) instead of being hardcoded at each use site.
enum AppInfo {
    /// `CFBundleShortVersionString` (the marketing version, e.g. "1.0"). The fallback
    /// only applies when running outside a bundle (e.g. a unit-test host).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// `CFBundleVersion` (the build number).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// "1.0 (1)" — version with build, for diagnostics and the About surface.
    static var versionWithBuild: String { "\(version) (\(build))" }
}
