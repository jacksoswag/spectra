import Foundation
import IOKit
import IOKit.ps
import QuartzCore

/// Reads the host's current battery charge so the REC-OSD battery icon can show
/// the real level instead of a fake animated drain.
///
/// Why a throttled static cache: `level()` is called once per *rendered* frame
/// (up to 60Hz) from the main thread, but the battery fraction changes on the
/// order of minutes — sampling IOKit power sources that often is pure waste and
/// touches a CF allocation each time. We therefore re-read IOKit at most once
/// every `sampleInterval` seconds and serve the cached value in between. The call
/// site is main-thread-only, so a plain non-atomic static cache is correct; it is
/// still written before being read (seeded on the first call) to stay robust.
enum BatteryProvider {
    /// Minimum wall-clock gap between IOKit re-reads. Battery percent moves slowly,
    /// so ~5s is far finer than any visible change while keeping the per-frame cost
    /// at essentially zero.
    private static let sampleInterval: CFTimeInterval = 5.0

    /// Last value handed out (0...1). Seeded to full so the very first frame — and
    /// every desktop Mac with no battery — reads a full bar.
    private static var cachedLevel: Float = 1.0
    /// `CACurrentMediaTime()` of the last IOKit sample, or a sentinel that forces an
    /// immediate first read.
    private static var lastSample: CFTimeInterval = -.greatestFiniteMagnitude

    /// Current battery fraction in 0...1. Returns 1.0 when the machine has no
    /// battery (desktop Macs) so the OSD bar reads full rather than empty.
    static func level() -> Float {
        let now = CACurrentMediaTime()
        if now - lastSample < sampleInterval {
            return cachedLevel
        }
        lastSample = now
        cachedLevel = readBatteryFraction()
        return cachedLevel
    }

    /// Query IOKit power sources directly. Walks every reported source and uses the
    /// first one that exposes both a current and max capacity (the internal
    /// battery); returns 1.0 if none do.
    private static func readBatteryFraction() -> Float {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return 1.0
        }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = info[kIOPSMaxCapacityKey] as? Int,
                  capacity > 0 else {
                continue
            }
            return min(1.0, Float(current) / Float(capacity))
        }
        return 1.0
    }
}
