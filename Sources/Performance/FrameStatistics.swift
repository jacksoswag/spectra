import Foundation

/// Aggregated, UI-facing performance summary for a display (or the whole app).
struct PerformanceSnapshot: Sendable, Equatable {
    var fps: Double = 0
    var frameInterval: Double = 0          // ms between presents
    var cpuMilliseconds: Double = 0        // avg encode time
    var gpuMilliseconds: Double = 0        // avg GPU time
    var gpuPeakMilliseconds: Double = 0
    var latencyMilliseconds: Double = 0    // avg capture→present
    var droppedPerSecond: Double = 0
    var passCount: Int = 0
    var sampleCount: Int = 0

    /// Headroom against a target frame budget (e.g. 16.67ms for 60Hz).
    func budgetFraction(targetMilliseconds: Double) -> Double {
        guard targetMilliseconds > 0 else { return 0 }
        return gpuMilliseconds / targetMilliseconds
    }
}

/// Thread-safe rolling buffer of frame samples for one display. Records happen on
/// the render completion thread; summaries are computed on demand (main actor).
final class FrameStatistics {
    private let lock = NSLock()
    private var samples: [FrameSample] = []
    private let capacity: Int
    private var presentTimestamps: [Double] = []
    private var dropTimestamps: [Double] = []

    init(capacity: Int = 240) {
        self.capacity = capacity
        samples.reserveCapacity(capacity)
    }

    func record(_ sample: FrameSample) {
        lock.lock()
        defer { lock.unlock() }
        if sample.dropped {
            dropTimestamps.append(sample.timestamp)
        } else {
            samples.append(sample)
            if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
            presentTimestamps.append(sample.timestamp)
        }
        let cutoff = sample.timestamp - 2.0
        presentTimestamps.removeAll { $0 < cutoff }
        dropTimestamps.removeAll { $0 < cutoff }
    }

    func snapshot() -> PerformanceSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var result = PerformanceSnapshot()
        result.sampleCount = samples.count
        guard !samples.isEmpty else { return result }

        let recent = Array(samples.suffix(120))
        let count = Double(recent.count)
        result.cpuMilliseconds = recent.reduce(0) { $0 + $1.cpuMilliseconds } / count
        result.gpuMilliseconds = recent.reduce(0) { $0 + $1.gpuMilliseconds } / count
        result.gpuPeakMilliseconds = recent.map(\.gpuMilliseconds).max() ?? 0
        result.latencyMilliseconds = recent.reduce(0) { $0 + $1.latencyMilliseconds } / count
        result.passCount = recent.last?.passCount ?? 0

        // FPS from present cadence over the recent window.
        if let first = presentTimestamps.first, let last = presentTimestamps.last, last > first {
            let span = last - first
            result.fps = Double(presentTimestamps.count - 1) / span
            result.frameInterval = span / Double(presentTimestamps.count - 1) * 1000.0
        }
        if let first = dropTimestamps.first, let last = dropTimestamps.last, last > first {
            result.droppedPerSecond = Double(dropTimestamps.count) / (last - first)
        } else if !dropTimestamps.isEmpty {
            result.droppedPerSecond = Double(dropTimestamps.count) / 2.0
        }
        return result
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        presentTimestamps.removeAll(keepingCapacity: true)
        dropTimestamps.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
