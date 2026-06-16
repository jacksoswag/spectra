import Foundation

/// A single rendered-frame measurement, emitted by each `DisplayRenderer` and
/// aggregated by the `PerformanceMonitor`.
struct FrameSample: Sendable {
    /// CPU time spent encoding the frame, in milliseconds.
    var cpuMilliseconds: Double
    /// GPU execution time for the frame, in milliseconds (0 if unavailable).
    var gpuMilliseconds: Double
    /// Total latency from capture timestamp to present, in milliseconds.
    var latencyMilliseconds: Double
    /// Number of GPU passes encoded.
    var passCount: Int
    /// Whether the frame was dropped (no in-flight slot or no drawable).
    var dropped: Bool
    /// Wall-clock time of the sample (`CACurrentMediaTime`).
    var timestamp: Double

    static let zero = FrameSample(
        cpuMilliseconds: 0, gpuMilliseconds: 0, latencyMilliseconds: 0,
        passCount: 0, dropped: false, timestamp: 0)
}
