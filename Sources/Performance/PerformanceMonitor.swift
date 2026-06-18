import Foundation
import Metal
import CoreGraphics
import Observation

/// Collects frame samples from every display renderer and publishes aggregated,
/// UI-facing snapshots. Ingestion is thread-safe (called from GPU completion
/// handlers); `refresh()` recomputes the observable summaries on the main actor
/// at a modest cadence, decoupling UI updates from the frame rate.
@MainActor
@Observable
final class PerformanceMonitor {
    private(set) var perDisplay: [CGDirectDisplayID: PerformanceSnapshot] = [:]
    private(set) var combined = PerformanceSnapshot()
    private(set) var vramMegabytes: Double = 0

    @ObservationIgnored private let statsLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var stats: [CGDirectDisplayID: FrameStatistics] = [:]
    @ObservationIgnored weak var device: MTLDevice?

    /// Record a frame sample. Safe to call from any thread.
    nonisolated func ingest(_ sample: FrameSample, displayID: CGDirectDisplayID) {
        statsFor(displayID).record(sample)
    }

    private nonisolated func statsFor(_ displayID: CGDirectDisplayID) -> FrameStatistics {
        statsLock.lock()
        defer { statsLock.unlock() }
        if let existing = stats[displayID] { return existing }
        let created = FrameStatistics()
        stats[displayID] = created
        return created
    }

    /// Recompute observable summaries. Call periodically from the UI.
    func refresh() {
        statsLock.lock()
        let entries = stats
        statsLock.unlock()

        var perDisplay: [CGDirectDisplayID: PerformanceSnapshot] = [:]
        for (id, statistics) in entries {
            perDisplay[id] = statistics.snapshot()
        }
        // @Observable fires on every assignment regardless of value, re-invalidating
        // each stats view (and any window rendering through the chain) twice a second.
        // Assign only on change. (The float averages jitter, so this mostly short-
        // circuits when rendering is idle; vram, below, is the reliable win.)
        if perDisplay != self.perDisplay { self.perDisplay = perDisplay }
        let newCombined = combine(perDisplay.values)
        if newCombined != combined { combined = newCombined }

        // VRAM feeds a live 0.5s timeline, so sample it every refresh. Reading the
        // allocated size is cheap and the assignment below is change-gated, so a steady
        // chain still produces no extra observer invalidations.
        if let device {
            let newVram = Double(device.currentAllocatedSize) / (1024 * 1024)
            if newVram != vramMegabytes { vramMegabytes = newVram }
        }
    }

    func snapshot(for displayID: CGDirectDisplayID) -> PerformanceSnapshot {
        perDisplay[displayID] ?? PerformanceSnapshot()
    }

    func removeDisplay(_ displayID: CGDirectDisplayID) {
        statsLock.lock()
        stats[displayID] = nil
        statsLock.unlock()
        perDisplay[displayID] = nil
    }

    /// Clear a single display's accumulated samples. Called when the render scale
    /// changes so timing re-measures the new resolution from scratch instead of
    /// averaging across the old (larger) frames.
    func resetStats(for displayID: CGDirectDisplayID) {
        statsLock.lock()
        stats[displayID]?.reset()
        statsLock.unlock()
        perDisplay[displayID] = nil
    }

    func reset() {
        statsLock.lock()
        stats.values.forEach { $0.reset() }
        statsLock.unlock()
        perDisplay = [:]
        combined = PerformanceSnapshot()
    }

    private func combine<S: Sequence>(_ snapshots: S) -> PerformanceSnapshot where S.Element == PerformanceSnapshot {
        var result = PerformanceSnapshot()
        var n = 0
        for snapshot in snapshots {
            n += 1
            result.fps += snapshot.fps
            result.cpuMilliseconds = max(result.cpuMilliseconds, snapshot.cpuMilliseconds)
            result.gpuMilliseconds = max(result.gpuMilliseconds, snapshot.gpuMilliseconds)
            result.gpuPeakMilliseconds = max(result.gpuPeakMilliseconds, snapshot.gpuPeakMilliseconds)
            result.latencyMilliseconds = max(result.latencyMilliseconds, snapshot.latencyMilliseconds)
            result.droppedPerSecond += snapshot.droppedPerSecond
            result.passCount = max(result.passCount, snapshot.passCount)
            result.sampleCount += snapshot.sampleCount
        }
        if n > 0 { result.fps /= Double(n) }
        return result
    }
}
