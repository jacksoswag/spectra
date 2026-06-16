import Foundation
import OSLog

/// Lightweight, category-scoped logging facade over `os.Logger`.
///
/// Centralising log construction keeps subsystem/category strings consistent
/// and gives a single place to adjust logging policy. Categories map onto the
/// architectural modules so Console.app filtering is meaningful.
enum Log {
    private static let subsystem = "com.spectra.Spectra"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let capture = Logger(subsystem: subsystem, category: "Capture")
    static let render = Logger(subsystem: subsystem, category: "Render")
    static let shader = Logger(subsystem: subsystem, category: "Shader")
    static let effects = Logger(subsystem: subsystem, category: "Effects")
    static let presets = Logger(subsystem: subsystem, category: "Presets")
    static let storage = Logger(subsystem: subsystem, category: "Storage")
    static let performance = Logger(subsystem: subsystem, category: "Performance")
    static let editor = Logger(subsystem: subsystem, category: "Editor")
}
