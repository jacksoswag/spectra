import Foundation
import ScreenCaptureKit
import CoreVideo
import Metal
import QuartzCore

/// Capture-start failures Spectra raises itself (vs. errors thrown by ScreenCaptureKit).
enum CaptureError: Error {
    /// The capture filter had no self-exclusion, which would let the overlay feed back.
    case missingSelfExclusion
}

/// A captured frame plus the Core Video texture that backs it. Holding `backing`
/// keeps the underlying IOSurface alive for as long as a consumer references
/// `texture`: the texture cache may otherwise recycle that surface for a newer
/// frame. The display-link consumer renders frames asynchronously, so it must
/// retain `backing` until its GPU work for the frame completes.
struct CapturedFrame {
    let texture: MTLTexture
    let backing: CVMetalTexture
    /// `CACurrentMediaTime()` at capture, for end-to-end latency measurement.
    let hostTime: Double
}

/// Captures a single display via ScreenCaptureKit and converts each frame to a
/// zero-copy `MTLTexture` (through a `CVMetalTextureCache`). Frames are delivered
/// on a dedicated high-priority queue via `frameHandler`; the most recent texture
/// is also retained for the live preview.
final class CaptureSession: NSObject, SCStreamDelegate, SCStreamOutput {
    let displayID: CGDirectDisplayID

    private let context: MetalContext
    private let queue: DispatchQueue
    private var stream: SCStream?

    private(set) var pixelWidth: Int
    private(set) var pixelHeight: Int
    private var targetFPS: Int
    private var showsCursor: Bool

    /// Invoked on the capture queue for every completed frame. Consumers must not
    /// block here (the queue also drives capture); store the frame and return.
    var frameHandler: ((CapturedFrame) -> Void)?
    /// Invoked on the main actor if the stream stops unexpectedly.
    var stopHandler: ((Error?) -> Void)?

    private let frameTimeLock = NSLock()
    private var _lastFrameTime: Double = 0
    /// Monotonic `CACurrentMediaTime()` of the last COMPLETE frame this stream
    /// delivered (0 before the first frame). Stamped continuously on the capture
    /// queue and read from the main-actor heartbeat to detect a stream that has
    /// silently stopped delivering frames (a Space-swipe stall: no `didStopWithError`).
    var lastFrameTime: Double {
        frameTimeLock.lock(); defer { frameTimeLock.unlock() }; return _lastFrameTime
    }

    init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int,
         showsCursor: Bool, context: MetalContext) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.targetFPS = fps
        self.showsCursor = showsCursor
        self.context = context
        self.queue = DispatchQueue(label: "com.spectra.capture.\(displayID)", qos: .userInteractive)
        super.init()
    }

    // MARK: - Lifecycle

    /// Start capturing `scDisplay`, excluding `applications` (Spectra, so the overlay
    /// never captures itself) but making exceptions for `windows` — Spectra's control
    /// windows — so they're captured and run through the effect chain like any other
    /// window. The overlay is never in `windows`, so it can never feed back.
    func start(scDisplay: SCDisplay, excluding applications: [SCRunningApplication],
               excepting windows: [SCWindow]) async throws {
        // Never build a filter without self-exclusion: an empty `applications` list
        // excludes nothing, so the opaque overlay (which SCK captures despite its
        // sharingType = .none) would film its own processed output and feed back.
        guard !applications.isEmpty else { throw CaptureError.missingSelfExclusion }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: applications, exceptingWindows: windows)
        let configuration = makeConfiguration()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.capture.info("Capture started for display \(self.displayID, privacy: .public) @ \(self.targetFPS)fps")
    }

    /// Update which control windows are excepted from the app exclusion (so a Studio
    /// or Settings window opened after capture started renders through the chain),
    /// applied live to a running stream.
    func updateFilter(scDisplay: SCDisplay, excluding applications: [SCRunningApplication],
                      excepting windows: [SCWindow]) async {
        // Drop a transient empty exclusion rather than replace a safely-excluding filter
        // with one that captures the overlay (which would feed back).
        guard let stream, !applications.isEmpty else { return }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: applications, exceptingWindows: windows)
        do {
            try await stream.updateContentFilter(filter)
        } catch {
            Log.capture.error("Update content filter failed: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            Log.capture.error("Stop capture failed: \(error.localizedDescription)")
        }
    }

    func reconfigure(pixelWidth: Int, pixelHeight: Int, fps: Int) async {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.targetFPS = fps
        await applyConfiguration()
    }

    /// Update whether the hardware cursor is composited into the capture, applied
    /// live to a running stream.
    func setShowsCursor(_ shows: Bool) async {
        guard showsCursor != shows else { return }
        showsCursor = shows
        await applyConfiguration()
    }

    private func applyConfiguration() async {
        guard let stream else { return }
        do {
            try await stream.updateConfiguration(makeConfiguration())
        } catch {
            Log.capture.error("Reconfigure failed: \(error.localizedDescription)")
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, targetFPS)))
        configuration.queueDepth = 5
        configuration.showsCursor = showsCursor
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.capturesAudio = false
        return configuration
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("Stream stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in self?.stopHandler?(error) }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard frameIsComplete(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let frame = makeFrame(from: pixelBuffer) else { return }
        frameTimeLock.lock(); _lastFrameTime = frame.hostTime; frameTimeLock.unlock()
        frameHandler?(frame)
    }

    private func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let statusRaw = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw) else {
            return true // older payloads without status are treated as complete
        }
        return status == .complete
    }

    private func makeFrame(from pixelBuffer: CVPixelBuffer) -> CapturedFrame? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, context.textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)

        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }

        // Release texture-cache entries that no longer have an external reference.
        // Without this the cache accumulates IOSurface-backed textures across a
        // session (a steady VRAM/memory climb). In-flight frames keep their own
        // `backing` CVMetalTexture, so their surfaces survive the flush.
        CVMetalTextureCacheFlush(context.textureCache, 0)

        return CapturedFrame(texture: texture, backing: cvTexture, hostTime: CACurrentMediaTime())
    }
}
