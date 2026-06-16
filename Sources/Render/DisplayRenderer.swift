import Foundation
import AppKit
import Metal
import QuartzCore

/// Drives the effect chain for a single display and presents the result onto its
/// overlay window.
///
/// Capture and presentation are decoupled. Frames arrive from the capture queue
/// via `submit(_:)`, which only stores the most recent frame and returns — it
/// never touches a drawable or the GPU. A `CAMetalDisplayLink` bound to the
/// overlay layer is the single render clock: it fires on the main run loop and, at
/// most `maxRenderFPS` times a second, renders the latest stored frame.
///
/// One clock, one cap. The render rate is deliberately *not* tied to how fast
/// capture delivers frames: the opaque overlay presenting to the screen makes the
/// window server mark the desktop dirty, which makes ScreenCaptureKit emit another
/// "changed" frame, which would drive another render — a compositor-level feedback
/// loop that pins the GPU. Capping the present rate (and capturing no faster) is
/// what breaks it. 60Hz is visually identical for these procedural effects.
final class DisplayRenderer: NSObject {
    let displayID: CGDirectDisplayID

    private let context: MetalContext
    private let shaders: ShaderLibrary
    private let pool: TexturePool
    private let chainRenderer: EffectChainRenderer
    private let overlay: OverlayWindow
    /// Composites the live cursor into the frame (before the chain) when the custom
    /// cursor is enabled. Used only on the main thread (the render callback).
    private let cursorCompositor: CursorCompositor

    /// Render-pipeline depth. Kept in lock-step with the overlay layer's
    /// `maximumDrawableCount` (OverlayWindow): 2 = double-buffered, which trims ~one
    /// frame of present latency versus triple-buffering at the cost of less spike
    /// headroom on heavy chains. Raise both back to 3 if drops climb.
    private let maxInFlight = 2
    private let inFlight: DispatchSemaphore
    private let startTime = CACurrentMediaTime()

    /// Hard ceiling on the render/present rate. Capture and the display link are both
    /// held at or below this; the user's Frame Rate setting can only lower it.
    private let maxRenderFPS = 60.0

    private let chainLock = NSLock()
    private var chain: [ResolvedEffect] = []

    /// Main-thread-only state (touched solely inside `renderFrame`, which runs on
    /// the display-link callback on the main run loop).
    private var frameCounter: Float = 0
    /// `CACurrentMediaTime()` of the last presented frame — drives the single render
    /// rate cap.
    private var lastRenderHostTime: Double = 0
    /// Previous frame's processed output, retained for feedback/history effects.
    private var historyTexture: MTLTexture?

    /// Mailbox between the capture queue (producer) and the display-link callback
    /// (consumer). `pendingFrame` is the newest unconsumed frame; `lastFrame` is the
    /// most recent rendered frame, kept so animated effects (and chain edits) can
    /// redraw without a fresh capture. `needsRedraw` forces one repaint after a
    /// chain/parameter change even when the captured screen is static. All guarded
    /// by `frameLock`.
    private let frameLock = NSLock()
    private var pendingFrame: CapturedFrame?
    private var lastFrame: CapturedFrame?
    private var needsRedraw = false

    /// The display link, created and torn down on the main thread (where its run
    /// loop lives). Activation only flips `isPaused`.
    private var displayLink: CAMetalDisplayLink?
    /// The user's Frame Rate setting (0 = use `maxRenderFPS`). Only ever lowers the
    /// effective cap below `maxRenderFPS`.
    private var preferredFrameRate: Int = 0

    /// Whether the overlay is presenting. Set from the main actor. When false the
    /// link is paused and no frames are presented (e.g. the display is hidden).
    private var _active = false
    var isActive: Bool {
        get { _active }
        set {
            guard _active != newValue else { return }
            _active = newValue
            if newValue {
                ensureDisplayLink()
                displayLink?.isPaused = false
            } else {
                displayLink?.isPaused = true
                clearMailbox()   // release the pinned capture surface while idle
            }
        }
    }

    /// Emits a measurement for every presented (or dropped) frame.
    var sampleHandler: ((FrameSample) -> Void)?
    /// Invoked (off the main thread) when a command buffer completes with a GPU
    /// error — e.g. a misbehaving imported shader. The coordinator uses this to
    /// recover rather than letting the fault repeat every frame.
    var faultHandler: ((Error?) -> Void)?

    init(displayID: CGDirectDisplayID, overlay: OverlayWindow, context: MetalContext, shaders: ShaderLibrary) {
        self.displayID = displayID
        self.overlay = overlay
        self.context = context
        self.shaders = shaders
        self.pool = TexturePool(device: context.device)
        self.chainRenderer = EffectChainRenderer(context: context, shaders: shaders, pool: pool)
        self.cursorCompositor = CursorCompositor(device: context.device, shaders: shaders)
        self.inFlight = DispatchSemaphore(value: maxInFlight)
        super.init()
    }

    /// Enable/disable drawing the live cursor into the frame (so it runs through
    /// the chain). Called from the main actor.
    func setCustomCursorEnabled(_ on: Bool) {
        cursorCompositor.enabled = on
    }

    /// Replace the chain rendered onto this display. Thread-safe.
    func updateChain(_ resolved: [ResolvedEffect]) {
        chainLock.lock()
        chain = resolved
        chainLock.unlock()
        // A chain/parameter edit must repaint even if the captured screen is static
        // (no new capture frame would otherwise arrive to drive the redraw).
        frameLock.lock()
        needsRedraw = true
        frameLock.unlock()
    }

    /// Whether any animated effect is present (drives idle-redraw decisions).
    var hasAnimatedEffect: Bool {
        chainLock.lock(); defer { chainLock.unlock() }
        return chain.contains { $0.descriptor.isAnimated }
    }

    /// Store the most recent captured frame for the render loop to consume. Called
    /// on the capture queue; never blocks (no drawable, no GPU work here), so the
    /// capture queue keeps delivering frames at full rate.
    func submit(_ frame: CapturedFrame) {
        frameLock.lock()
        pendingFrame = frame
        frameLock.unlock()
    }

    // MARK: - Display-link lifecycle (main thread)

    /// Create the display link (once) and attach it to the main run loop in the
    /// common modes, so it keeps firing while the user interacts with menus etc.
    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: overlay.metalLayer)
        link.delegate = self
        link.isPaused = true
        applyPreferredFrameRate(to: link)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Lower the render/present rate to the user's Frame Rate setting. Never raises
    /// it above `maxRenderFPS`.
    func setPreferredFrameRate(_ fps: Int) {
        guard fps != preferredFrameRate else { return }
        preferredFrameRate = fps
        if let displayLink { applyPreferredFrameRate(to: displayLink) }
    }

    /// The single effective render cap: `maxRenderFPS`, lowered by the user setting.
    private var renderFPSCap: Double {
        preferredFrameRate > 0 ? min(Double(preferredFrameRate), maxRenderFPS) : maxRenderFPS
    }

    private func applyPreferredFrameRate(to link: CAMetalDisplayLink) {
        let target = Float(renderFPSCap)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(min(30, Int(target))), maximum: target, preferred: target)
    }

    private func clearMailbox() {
        frameLock.lock()
        pendingFrame = nil
        lastFrame = nil
        frameLock.unlock()
    }

    /// Drop any buffered frames so the overlay cannot re-present a pre-transition
    /// (stale) frame. Called on the main thread when a Space change begins, before the
    /// overlay is hidden and later carried onto the now-active Space — otherwise the
    /// animated-chain idle redraw keeps painting the stale frame and it gets
    /// force-fronted as the "frozen Mission Control" ghost. The next render waits for a
    /// fresh capture. Unlike `clearMailbox` this also drops a pending one-shot redraw.
    func discardBufferedFrames() {
        frameLock.lock()
        pendingFrame = nil
        lastFrame = nil
        needsRedraw = false
        frameLock.unlock()
    }

    /// Stop rendering and release resources (display removed / app shutdown).
    func teardown() {
        isActive = false           // pause the link
        displayLink?.invalidate()  // detaches from the run loop; no more callbacks
        displayLink = nil
        clearMailbox()
        pool.purge()
    }

    // MARK: - Frame rendering (main thread, via the display-link callback)

    /// Render and present a captured frame onto `drawable`. Drops the frame
    /// (reporting it) if no in-flight slot is available.
    private func renderFrame(_ frame: CapturedFrame, drawable: CAMetalDrawable) {
        let encodeStart = CACurrentMediaTime()

        guard inFlight.wait(timeout: .now()) == .success else {
            requestRedraw()   // no GPU slot this tick; retry on the next one
            report(dropped: true, cpu: 0, gpu: 0, latency: 0, passes: 0)
            return
        }

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            requestRedraw()
            report(dropped: true, cpu: 0, gpu: 0, latency: 0, passes: 0)
            return
        }
        commandBuffer.label = "Spectra.display.\(displayID)"

        chainLock.lock()
        let snapshot = chain
        chainLock.unlock()

        let time = Float(CACurrentMediaTime() - startTime)
        frameCounter += 1
        let clock = FrameContext.liveClock()
        let frameContext = FrameContext(
            time: time, frameIndex: frameCounter,
            clockSeconds: clock.clockSeconds,
            year: clock.year, month: clock.month, day: clock.day,
            batteryLevel: BatteryProvider.level())

        // Optionally draw the live cursor into the frame so it goes through the
        // chain. The composited texture (if any) is released on GPU completion.
        let cursorComposite = cursorCompositor.composite(
            input: frame.texture, displayFramePoints: overlay.frame,
            into: commandBuffer, pool: pool)
        let chainInput = cursorComposite ?? frame.texture

        let needsHistory = snapshot.contains { $0.descriptor.needsHistory }
        let result = chainRenderer.encode(
            into: commandBuffer, input: chainInput, chain: snapshot, frame: frameContext,
            history: needsHistory ? historyTexture : nil)

        // Capture this frame's output as next frame's history (feedback loop).
        if needsHistory {
            updateHistory(from: result.outputTexture, in: commandBuffer)
        } else {
            historyTexture = nil
        }

        // Present pass: copy the chain output onto the drawable (format convert).
        let presented = presentTexture(result.outputTexture, to: drawable.texture, in: commandBuffer)

        let transient = result.transientTextures
        let passes = result.passCount

        let cpuMilliseconds = (CACurrentMediaTime() - encodeStart) * 1000.0
        let captureHostTime = frame.hostTime

        // Capture pool + semaphore strongly so a teardown mid-flight cannot
        // deallocate the DispatchSemaphore below its initial count (a libdispatch
        // trap): every committed frame signals exactly once regardless of self.
        let pool = self.pool
        let inFlight = self.inFlight
        let displayID = self.displayID
        let releasedCursor = cursorComposite
        commandBuffer.addCompletedHandler { [weak self] buffer in
            // Retain the captured frame (and its CV backing) until the GPU has
            // finished reading it, so the texture cache cannot recycle the surface.
            withExtendedLifetime(frame) {}
            pool.release(transient)
            if let releasedCursor { pool.release([releasedCursor]) }
            if buffer.status == .error {
                Log.render.error("GPU command buffer error on display \(displayID): \(buffer.error?.localizedDescription ?? "unknown")")
                self?.faultHandler?(buffer.error)
                self?.report(dropped: true, cpu: cpuMilliseconds, gpu: 0, latency: 0, passes: passes)
            } else {
                let gpuMilliseconds = max(0, (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0)
                let latency = max(0, (CACurrentMediaTime() - captureHostTime) * 1000.0)
                self?.report(dropped: false, cpu: cpuMilliseconds, gpu: gpuMilliseconds,
                             latency: latency, passes: passes)
            }
            inFlight.signal()
        }

        // Only present a drawable we actually drew into; otherwise commit (to
        // release pool textures and signal) but skip the present and retry.
        if presented {
            commandBuffer.present(drawable)
        } else {
            requestRedraw()
        }
        commandBuffer.commit()
    }

    /// Ask the next display-link tick to repaint (used when a frame is dropped or
    /// deferred by the rate cap so a one-shot redraw isn't lost).
    private func requestRedraw() {
        frameLock.lock()
        needsRedraw = true
        frameLock.unlock()
    }

    /// Copy the chain output into the persistent history texture (recreating it on
    /// a size change) so the next frame's feedback effects can sample it.
    private func updateHistory(from output: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        if historyTexture?.width != output.width || historyTexture?.height != output.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: MetalContext.workingPixelFormat,
                width: output.width, height: output.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            historyTexture = context.device.makeTexture(descriptor: descriptor)
        }
        guard let history = historyTexture, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: output, to: history)
        blit.endEncoding()
    }

    /// Returns true if the drawable was actually rendered into (so it's safe to
    /// present), false if the present pipeline/encoder was unavailable.
    private func presentTexture(_ source: MTLTexture, to target: MTLTexture, in commandBuffer: MTLCommandBuffer) -> Bool {
        guard let pipeline = try? shaders.pipeline(fragment: "present_fragment", pixelFormat: target.pixelFormat) else {
            return false
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        encoder.label = "Spectra.present.\(displayID)"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func report(dropped: Bool, cpu: Double, gpu: Double, latency: Double, passes: Int) {
        sampleHandler?(FrameSample(
            cpuMilliseconds: cpu, gpuMilliseconds: gpu, latencyMilliseconds: latency,
            passCount: passes, dropped: dropped, timestamp: CACurrentMediaTime()))
    }

    func purge() {
        pool.purge()
    }
}

// MARK: - CAMetalDisplayLinkDelegate

extension DisplayRenderer: CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard isActive else { return }

        frameLock.lock()
        let hasNew = pendingFrame != nil
        let redraw = needsRedraw
        needsRedraw = false
        let frame = pendingFrame ?? lastFrame
        if let pendingFrame { lastFrame = pendingFrame }
        pendingFrame = nil
        frameLock.unlock()

        guard let frame else { return }                              // nothing captured yet
        guard hasNew || redraw || hasAnimatedEffect else { return }  // idle: nothing changed

        // Cap the render rate without inducing a beat. `CAMetalDisplayLink` already
        // fires at `renderFPSCap` (preferredFrameRateRange); this wall-clock check is a
        // backstop against a panel that over-fires the cap (e.g. ProMotion ignoring the
        // max hint) re-dirtying the captured scene into a compositor feedback loop.
        //
        // The threshold is one interval MINUS a tolerance, not a strict `1/cap`. When
        // the panel runs at exactly the cap (e.g. 60.00Hz) a tick lands ~one interval
        // after the last render, and sub-frame jitter pushes `delta` a hair under a
        // strict threshold — deferring that tick to the next one HALVES the rate to ~30
        // (the "stuck at 35-40fps, quality has no effect" symptom). The tolerance (1/5
        // of an interval, ~3.3ms at 60Hz) absorbs that jitter so every on-time tick
        // renders, while a genuine over-fire (delta well under the interval) is still
        // deferred — the tolerance stays below one panel-frame on 120/144/240Hz panels.
        let now = CACurrentMediaTime()
        let interval = 1.0 / renderFPSCap
        if now - lastRenderHostTime < interval - interval * 0.2 {
            if hasNew || redraw { requestRedraw() }
            return
        }
        lastRenderHostTime = now

        renderFrame(frame, drawable: update.drawable)
    }
}
