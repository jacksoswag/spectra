import Foundation
import QuartzCore
import ScreenCaptureKit
import CoreMedia
import AVFoundation

/// Samples system audio and publishes a level + three coarse bands (bass / mid / treble) for the
/// audio-reactive effects (MAOE §15.1), injected into `FrameContext` like `batteryLevel`. Runs
/// its OWN minimal ScreenCaptureKit stream (audio on, tiny video) so it stays decoupled from the
/// per-display render capture; SCK system-audio rides the Screen Recording grant already held.
/// Engaged only while a world opts in AND the global toggle is on, so it costs nothing otherwise.
///
/// The render (link) thread reads the latest snapshot lock-free via `current()`.
@MainActor
final class AudioReactor: NSObject, SCStreamDelegate, SCStreamOutput {
    struct Snapshot: Sendable {
        var level: Float = 0
        var bass: Float = 0
        var mid: Float = 0
        var treble: Float = 0
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var snapshot = Snapshot()

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.spectra.audioreactor", qos: .userInitiated)
    private(set) var enabled = false
    /// Consecutive automatic restart attempts after an unexpected stream stop (reset on a
    /// clean start). Bounds the exponential-backoff recovery so a persistently failing audio
    /// device doesn't spin forever. Main-actor only.
    private var restartAttempts = 0
    /// True while a `start()` is in flight (from its first suspension until it completes). Because
    /// `self.stream` is only assigned after `startCapture()` returns, this is what stops a
    /// concurrent `setEnabled(true)` or a backoff restart from launching a second SCStream that
    /// would leak and keep firing callbacks. Main-actor only.
    private var starting = false

    // Envelope-followed band energies (smoothed in the audio callback).
    nonisolated(unsafe) private var envLevel: Float = 0
    nonisolated(unsafe) private var envBass: Float = 0
    nonisolated(unsafe) private var envMid: Float = 0
    nonisolated(unsafe) private var envTreble: Float = 0
    nonisolated(unsafe) private var lpState: Float = 0   // one-pole low-pass memory (bass)
    nonisolated(unsafe) private var prevSample: Float = 0

    nonisolated func current() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    private nonisolated func publish(_ s: Snapshot) { lock.lock(); snapshot = s; lock.unlock() }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { Task { await start() } } else { Task { await stop() } }
    }

    private func start() async {
        guard stream == nil, !starting else { return }   // a start is already in flight or live
        starting = true
        defer { starting = false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let display = content.displays.first else { return }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.width = 2; cfg.height = 2                  // minimal video; we only want the audio tap
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            restartAttempts = 0   // a clean start clears the backoff counter
        } catch {
            Log.capture.error("AudioReactor stream failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stop() async {
        restartAttempts = 0
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        resetEnvelope()
    }

    /// Reset the snapshot and the envelope state under the lock: the audio callback can still fire
    /// on `queue` while `stopCapture()` is suspended, and it reads/writes the same fields. Kept
    /// synchronous (NSLock is unavailable across `async` suspension points).
    private nonisolated func resetEnvelope() {
        lock.lock()
        snapshot = Snapshot()
        envLevel = 0; envBass = 0; envMid = 0; envTreble = 0
        lock.unlock()
    }

    /// Recover from an unexpected stream stop (SCK interruption, audio device change). Without
    /// this, the audio-reactive effects would freeze on their last envelope values silently.
    private func handleStopped() {
        stream = nil
        guard enabled else { return }   // a user-requested stop never auto-restarts
        guard restartAttempts < 3 else {
            Log.capture.warning("AudioReactor giving up after \(self.restartAttempts) restart attempts")
            return
        }
        let delay = pow(2.0, Double(restartAttempts)) * 0.5   // 0.5s, 1s, 2s
        restartAttempts += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.enabled, self.stream == nil else { return }
            await self.start()
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sb) else { return }
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let data = abl.mBuffers.mData else { return }
        let count = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)

        var sumSq: Float = 0, sumBass: Float = 0, sumTreble: Float = 0
        let lpCoeff: Float = 0.05   // one-pole low-pass for bass
        var lp = lpState, prev = prevSample
        for i in 0..<count {
            let s = samples[i]
            sumSq += s * s
            lp += lpCoeff * (s - lp)
            sumBass += lp * lp
            let hp = s - prev               // crude high-pass (first difference)
            sumTreble += hp * hp
            prev = s
        }
        lpState = lp; prevSample = prev
        let n = Float(count)
        let level = min(1, sqrt(sumSq / n) * 4)
        let bass = min(1, sqrt(sumBass / n) * 6)
        let treble = min(1, sqrt(sumTreble / n) * 3)
        let mid = max(0, min(1, level - bass * 0.5))
        // Envelope follow: fast attack, slow release, so the bands read musically. Updated under
        // the lock because `stop()` (main actor) can zero these same fields concurrently.
        func follow(_ env: Float, _ x: Float) -> Float { x > env ? x : env + (x - env) * 0.2 }
        lock.lock()
        envLevel = follow(envLevel, level); envBass = follow(envBass, bass)
        envMid = follow(envMid, mid); envTreble = follow(envTreble, treble)
        snapshot = Snapshot(level: envLevel, bass: envBass, mid: envMid, treble: envTreble)
        lock.unlock()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("AudioReactor stopped: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor [weak self] in self?.handleStopped() }
    }
}
