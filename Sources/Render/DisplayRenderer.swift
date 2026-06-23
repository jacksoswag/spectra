import Foundation
import AppKit
import Metal
import QuartzCore

/// Thread-safe holder for the last Space-switch time (MAOE §5.2). `RenderEngine` stamps it
/// once a Space transition has settled; each `DisplayRenderer` reads it on the link thread to
/// derive `spaceAge` for the space-transition effects. A shared reference (not a closure) so
/// crossing the main → link thread boundary stays trivially `Sendable`.
final class SpaceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _time: Double = -1
    func stamp() { lock.lock(); _time = CACurrentMediaTime(); lock.unlock() }
    /// `CACurrentMediaTime()` of the last settled Space switch, or -1 if none yet.
    func time() -> Double { lock.lock(); defer { lock.unlock() }; return _time }
}

/// Drives the effect chain for a single display and presents the result onto its
/// overlay window.
///
/// Capture and presentation are decoupled. Frames arrive from the capture queue
/// via `submit(_:)`, which only stores the most recent frame and returns — it
/// never touches a drawable or the GPU. A window-tied `CAMetalDisplayLink` bound to
/// the overlay layer is the single render clock: it fires on the main run loop and,
/// at most `maxRenderFPS` times a second, draws the latest stored frame onto the
/// layer's `nextDrawable()`.
///
/// Why a window-tied `CAMetalDisplayLink` and not a screen-tied `NSScreen.displayLink`:
/// the metal link actively drives the layer at the full display refresh (60), whereas
/// the screen-tied variant follows the display's *adaptive* rate, which macOS throttles
/// to ~30 for the opaque, low-motion overlay (tried and reverted). The tradeoff is that
/// a window-tied link stops delivering callbacks the instant the overlay window is
/// hidden via `orderOut`, re-ordered (a Space carry), or its Space leaves the screen —
/// and never resumes. A dead clock on an opaque overlay froze it on a stale frame (the
/// Space-freeze / ghosted menu bar / missing cursor cluster). Two things keep it alive:
/// the overlay is hidden during a swipe with `alphaValue` (which leaves the layer — and
/// the link — attached) rather than `orderOut`, and `rebuildDisplayLink` re-creates the
/// link after every Space carry.
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
    /// Composites the live cursor into the frame (before the chain) when the custom cursor is
    /// enabled. Stateless; reads an immutable snapshot the shared main-actor `cursorSampler`
    /// publishes, so it runs on the off-main link thread.
    private let cursorCompositor: CursorCompositor
    /// Persistent draw-on-screen accumulation layer for the Pencil draw tool (red channel = stroke
    /// mask). Created lazily at chain resolution and kept ACROSS frames (never pooled), so strokes
    /// persist; stamped while the left button drags and cleared on a right-click. Only ever touched
    /// on the link thread, and only while the Pencil chain is active.
    private var pencilLayer: MTLTexture?
    private var pencilPrevUV = SIMD2<Float>(-1, -1)   // last stamped point (-1 = stroke not started)
    private var pencilSmoothedUV = SIMD2<Float>(-1, -1)   // low-passed draw point: a slight jitter smooth
    private var pencilAnchorUV = SIMD2<Float>(-1, -1)  // press point; a stroke begins only once the cursor moves off it
    private var pencilPrevLeft = false                // left-button state last frame (double-click edge detect)
    private var pencilLastLeftDown: Double = -2        // time of the previous left-down (double-click-to-clear)
    private var pencilLastLeftDownPos = CGPoint.zero
    /// Shared main-actor sampler that reads the live cursor (NSEvent/NSCursor) on the main
    /// thread and publishes a thread-safe snapshot the link-thread callback consumes.
    private let cursorSampler: CursorSampler
    /// Shared main-actor sampler that reads the live pointer (position, button, clicks) for the
    /// interactive effects, published as a thread-safe snapshot this link-thread callback folds
    /// into each frame's `FrameContext`.
    private let pointerSampler: PointerInputSampler
    /// Reused link-thread buffer for the pointer trail in UV (capacity = `trailCount`), so a held
    /// or recently-released drag doesn't allocate a fresh array every frame. `pointerTrailCount`
    /// carries how many entries are valid; assigning it into `FrameContext` shares it copy-on-write
    /// and the frame is consumed before the next fill, so no copy is made.
    private var pointerTrailScratch = [SIMD2<Float>](repeating: .zero, count: PointerInputSampler.trailCount)
    /// Shared provider publishing per-display window rectangles (CGWindowList → display-local
    /// UV) for window-aware effects. Lock-free read on the link thread; empty when no
    /// rect-consuming effect is in any chain.
    private let windowGeometry: WindowGeometryProvider
    /// Shared Space-switch clock (set by the engine after a switch settles); read on the link
    /// thread to derive `spaceAge`.
    private let spaceClock: SpaceClock
    /// Shared audio reactor (MAOE §15.1); lock-free read on the link thread. Inert when disabled.
    private let audioReactor: AudioReactor
    /// Hosts the `CAMetalDisplayLink` callback OFF the main run loop, so SwiftUI (the Studio
    /// window) laying out can't delay a tick and add ~one frame of latency. The link object's
    /// lifecycle (create/pause/rebuild/invalidate) still runs on the main thread; only the
    /// per-frame callback executes on this thread.
    private let linkThread = RenderLinkThread()

    /// Render-pipeline depth. Kept in lock-step with the overlay layer's
    /// `maximumDrawableCount` (OverlayWindow): 2 = double-buffered, which trims ~one
    /// frame of present latency versus triple-buffering at the cost of less spike
    /// headroom on heavy chains. Raise both back to 3 if drops climb.
    private let maxInFlight = 2
    private let inFlight: DispatchSemaphore
    private let startTime = CACurrentMediaTime()

    /// Guards the handful of scalars the main thread writes and the link-thread callback
    /// reads: `_active`, `intensityScale`, `preferredFrameRate`, `cachedFramePoints`,
    /// `lastCallbackTime`. Everything else is either `frameLock`-guarded (the mailbox) or
    /// confined to one thread (`frameCounter`/`historyTexture`/`lastRenderHostTime` are
    /// link-thread only; the reveal state is main only).
    private let stateLock = NSLock()
    /// The overlay's frame in AppKit global points, cached on the main thread (the link thread
    /// must not read `NSWindow.frame`); the cursor composite places against it.
    private var cachedFramePoints: CGRect = .zero

    /// Hard ceiling on the render/present rate. Capture and the display link are both
    /// held at or below this; the user's Frame Rate setting can only lower it.
    private let maxRenderFPS = 60.0

    /// Global intensity multiplier (the master "intensity" slider), pushed in from
    /// the engine and injected into every frame's `FrameContext`. Main-thread only
    /// (set from the main actor, read in the display-link callback).
    private var intensityScale: Float = 1.0

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
    /// MAOE §5.2 decay render gate. The link callback treats the frame as live while
    /// `CACurrentMediaTime() < decayExpiresAt`, then drops back to idle — the single mechanism
    /// behind every one-shot event effect (click bursts, scroll drift, space transitions, the
    /// press-hold line warp). Guarded by `stateLock`; armed from arbitrary threads via
    /// `armDecay`. A one-shot effect NEVER forces continuous rendering, so idle cost stays zero.
    private var decayExpiresAt: Double = 0
    /// Most recent window-lifecycle event for this display (MAOE §5.4), stored so the event
    /// block can age it out for the close/minimize/open bursts. `stateLock`-guarded; written
    /// from the geometry provider's routing on the main thread, read on the link thread.
    private var lifecycleKind: Float = 0          // 0 none, 1 opened, 2 closed, 3 minimized
    private var lifecycleRect: SIMD4<Float> = .zero
    private var lifecycleDockDir: SIMD2<Float> = .zero
    private var lifecycleTime: Double = -1
    /// One-shot styled-capture request (MAOE §15.4). Set on the main actor, consumed once on the
    /// next rendered frame on the link thread. `stateLock`-guarded.
    private var captureRequest: ((CGImage?) -> Void)?
    /// Monotonic id of each captured frame, bumped in `submit` (capture queue) and
    /// carried through the mailbox so the consumer can tell a brand-new capture from a
    /// redraw of `lastFrame`. Used only by the frame-gated reveal. Guarded by `frameLock`.
    private var submitSeq: UInt64 = 0
    private var pendingSeq: UInt64 = 0
    private var lastFrameSeq: UInt64 = 0

    /// Frame-gated reveal (used by the engine to un-hide the overlay after a Space
    /// switch only once a FRESH frame for the new Space has actually been presented,
    /// instead of revealing a stale frame on a timer). Armed on the main actor, fired
    /// from the render callback — both run on the main thread, so no lock is needed.
    /// `.max` = disarmed.
    private var revealTargetSeq: UInt64 = .max
    private var revealHandler: (() -> Void)?
    /// How many freshly-captured frames past the arm point must be presented before the
    /// reveal fires. >1 drains any transition frame the capture queue had buffered when
    /// the gate was armed, so the reveal never flashes leftover swipe content.
    private static let revealFreshFrameCount: UInt64 = 2

    /// The render clock, created and torn down on the main thread (where its run loop
    /// lives). Activation only flips `isPaused`. See `ensureDisplayLink` for why it's a
    /// window-tied `CAMetalDisplayLink` and how a Space carry rebuilds it.
    private var displayLink: CAMetalDisplayLink?
    /// The user's Frame Rate setting (0 = use `maxRenderFPS`). Only ever lowers the
    /// effective cap below `maxRenderFPS`.
    private var preferredFrameRate: Int = 0

    /// `CACurrentMediaTime()` of the last display-link callback. The watchdog keys on
    /// callback DELIVERY (not renders) to detect a clock that has silently stalled — the
    /// window-tied `CAMetalDisplayLink` stops firing after some Space carries, and without a
    /// rebuild the overlay freezes on a stale frame until the user re-swipes. Main thread only.
    private var lastCallbackTime: Double = 0
    private var lastWatchdogRebuild: Double = 0

    /// Whether the overlay is presenting. Set from the main actor. When false the
    /// link is paused and no frames are presented (e.g. the display is hidden).
    private var _active = false
    var isActive: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _active }
        set {
            stateLock.lock()
            guard _active != newValue else { stateLock.unlock(); return }
            _active = newValue
            stateLock.unlock()
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

    init(displayID: CGDirectDisplayID, overlay: OverlayWindow, context: MetalContext,
         shaders: ShaderLibrary, cursorSampler: CursorSampler, pointerSampler: PointerInputSampler,
         windowGeometry: WindowGeometryProvider, spaceClock: SpaceClock, audioReactor: AudioReactor) {
        self.displayID = displayID
        self.overlay = overlay
        self.context = context
        self.shaders = shaders
        self.cursorSampler = cursorSampler
        self.pointerSampler = pointerSampler
        self.windowGeometry = windowGeometry
        self.spaceClock = spaceClock
        self.audioReactor = audioReactor
        self.pool = TexturePool(device: context.device)
        self.chainRenderer = EffectChainRenderer(context: context, shaders: shaders, pool: pool)
        self.cursorCompositor = CursorCompositor(shaders: shaders)
        self.inFlight = DispatchSemaphore(value: maxInFlight)
        self.cachedFramePoints = overlay.frame
        super.init()
    }

    /// Fold the live pointer snapshot into this frame's context, converted to THIS display's UV
    /// (top-left origin, matching `in.uv`). Uses the same global-point → UV mapping as the cursor
    /// compositor, so the splash lands exactly under the real pointer. Cheap; runs on the link
    /// thread (the sampler's `current()` is lock-free). Inert when the sampler is disengaged.
    private func applyPointer(to ctx: inout FrameContext, framePoints frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let snapshot = pointerSampler.current()
        let now = CACurrentMediaTime()
        func toUV(_ p: CGPoint) -> SIMD2<Float> {
            SIMD2(Float((p.x - frame.minX) / frame.width),
                  Float((frame.height - (p.y - frame.minY)) / frame.height))   // flip to top-left
        }
        // Event ages (MAOE §5.2). Display-agnostic — scroll/space/press are global signals — so
        // they are always folded in; the injection allowlist (`eventEffectFunctions`) decides
        // which effects actually read them.
        if snapshot.lastScrollTime >= 0 {
            ctx.scrollAge = Float(now - snapshot.lastScrollTime)
            ctx.scrollDelta = SIMD2(Float(snapshot.scrollDelta.dx), Float(snapshot.scrollDelta.dy))
        }
        let spaceTime = spaceClock.time()
        if spaceTime >= 0 { ctx.spaceAge = Float(now - spaceTime) }
        ctx.pressAge = (snapshot.pressed && snapshot.lastDownTime >= 0)
            ? Float(now - snapshot.lastDownTime) : 999
        // Current pointer + speed for the movement-reactive effects. (-1,-1) UV when the
        // pointer is on another display, so an effect only reacts on the screen it's over.
        if frame.contains(snapshot.pointerPos) {
            ctx.currentPointer = toUV(snapshot.pointerPos)
            ctx.pointerSpeed = Float(snapshot.pointerSpeed / frame.height)   // UV/sec
            ctx.moveAge = snapshot.lastMoveTime >= 0 ? Float(now - snapshot.lastMoveTime) : 999
        }
        // Window-lifecycle burst (MAOE §5.4): age the stored event so the close/minimize/open
        // burst self-decays. Read under the same lock used by the link callback for intensity.
        stateLock.lock()
        let lcTime = lifecycleTime, lcKind = lifecycleKind
        let lcRect = lifecycleRect, lcDock = lifecycleDockDir
        stateLock.unlock()
        if lcTime >= 0 {
            ctx.lifecycleAge = Float(now - lcTime)
            ctx.lifecycleKind = lcKind
            ctx.lifecycleRect = lcRect
            ctx.dockDirection = lcDock
        }
        // Ambient inputs (MAOE §15.1): keystroke age/seed from the pointer sampler, audio from
        // the reactor. Inert unless the respective feature is engaged.
        if snapshot.lastKeyTime >= 0 {
            ctx.keyAge = Float(now - snapshot.lastKeyTime)
            ctx.keyChar = Float(snapshot.keySeed)
        }
        let audio = audioReactor.current()
        ctx.audioLevel = audio.level
        ctx.audioBands = SIMD3(audio.bass, audio.mid, audio.treble)
        // Confine each interaction to the display it actually happens on: a click or drag on
        // another screen must not make this one run the splash (its geometry is off-canvas, but
        // the crown's droplet loop would still burn fullscreen GPU for its whole lifetime).
        if snapshot.lastDownTime >= 0, frame.contains(snapshot.lastDownPos) {
            ctx.clickPoint = toUV(snapshot.lastDownPos)
            ctx.clickAge = Float(now - snapshot.lastDownTime)
        }
        let headOnDisplay = snapshot.trailLength > 0 && frame.contains(snapshot.trail[0])
        guard headOnDisplay else { return }
        ctx.pressActive = snapshot.pressed ? 1 : 0
        ctx.releaseAge = snapshot.lastUpTime >= 0 ? Float(now - snapshot.lastUpTime) : 999
        // Only build the trail while it's needed (held, or within the release-collapse window);
        // a long-idle frozen trail otherwise burns work every frame for nothing. Fill the reused
        // scratch buffer rather than allocating a fresh array per frame.
        if snapshot.pressed || (snapshot.lastUpTime >= 0 && now - snapshot.lastUpTime < 1.0) {
            let n = min(snapshot.trailLength, PointerInputSampler.trailCount)
            for i in 0..<n { pointerTrailScratch[i] = toUV(snapshot.trail[i]) }
            ctx.pointerTrail = pointerTrailScratch
            ctx.pointerTrailCount = Float(n)
        }
    }

    /// CPU mirror of `PencilStampUniforms` in Pencil.metal (same field order + padding).
    private struct PencilStampUniforms { var prev: SIMD2<Float>; var cur: SIMD2<Float>; var halfWidth: Float; var aspect: Float }

    /// Maintain the Pencil draw layer (link thread): create it at the chain resolution, clear it on
    /// a right-click (or on first creation), and stamp a soft graphite mark from the previous to the
    /// current cursor while the LEFT button drags (width inverse to speed, so a slow stroke is
    /// thicker). Returns the layer to bind for `fx_int_pencilDraw`. Only called while the Pencil
    /// chain is active, so it is zero-cost for every other preset.
    private func updatePencilLayer(chainInput: MTLTexture, framePoints frame: CGRect,
                                   into commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let w = chainInput.width, h = chainInput.height
        guard w > 0, h > 0, frame.width > 0, frame.height > 0 else { return nil }
        var created = false
        if pencilLayer?.width != w || pencilLayer?.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            pencilLayer = context.device.makeTexture(descriptor: desc)
            pencilPrevUV = SIMD2(-1, -1)
            pencilSmoothedUV = SIMD2(-1, -1)
            created = true
        }
        guard let layer = pencilLayer else { return nil }
        let snapshot = pointerSampler.current()

        // Clear on a left DOUBLE-click (or when the layer was just created — private storage is
        // uninitialized). A double-click is two left-down edges within 0.4 s at ~the same spot; the
        // move-gate below means each of those clicks leaves no mark, so the gesture only erases.
        let now = CACurrentMediaTime()
        let leftDownEdge = snapshot.leftPressed && !pencilPrevLeft
        pencilPrevLeft = snapshot.leftPressed
        var doClear = created
        if leftDownEdge {
            let ddx = snapshot.pointerPos.x - pencilLastLeftDownPos.x
            let ddy = snapshot.pointerPos.y - pencilLastLeftDownPos.y
            if now - pencilLastLeftDown < 0.4 && ddx * ddx + ddy * ddy < 144 {
                doClear = true
                pencilLastLeftDown = -2   // consume, so a triple-click isn't a second clear
            } else {
                pencilLastLeftDown = now
                pencilLastLeftDownPos = snapshot.pointerPos
            }
        }
        if doClear {
            pencilPrevUV = SIMD2(-1, -1); pencilSmoothedUV = SIMD2(-1, -1); pencilAnchorUV = SIMD2(-1, -1)
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = layer
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
        }

        // Stamp while the LEFT button drags. The stroke begins only once the cursor has MOVED off the
        // press point, so a single click leaves no dot.
        if snapshot.leftPressed, frame.contains(snapshot.pointerPos),
           let pipeline = try? shaders.maxBlendPipeline(fragment: "fx_pencil_stamp", pixelFormat: .r16Float) {
            let raw = SIMD2<Float>(Float((snapshot.pointerPos.x - frame.minX) / frame.width),
                                   Float((frame.height - (snapshot.pointerPos.y - frame.minY)) / frame.height))
            if pencilAnchorUV.x < 0 { pencilAnchorUV = raw }                        // remember where this press began
            let mdx = raw.x - pencilAnchorUV.x, mdy = raw.y - pencilAnchorUV.y
            let started = pencilPrevUV.x >= 0 || mdx * mdx + mdy * mdy > 0.004 * 0.004
            if started {
                // Slight path smoothing: a light low-pass that rounds off pointer jitter with barely
                // any lag (0.7 = mostly the raw point, a touch of history). The stroke's first segment
                // runs from the press point so it starts exactly where the cursor went down.
                let smooth: Float = 0.7
                pencilSmoothedUV = pencilSmoothedUV.x < 0 ? raw : smooth * raw + (1 - smooth) * pencilSmoothedUV
                let cur = pencilSmoothedUV
                let prev = pencilPrevUV.x < 0 ? pencilAnchorUV : pencilPrevUV
                let speedUV = Float(snapshot.pointerSpeed / frame.height)               // UV/sec
                let halfW = max(0.0007, 0.0035 - min(speedUV, 1.2) / 1.2 * 0.0028)      // slow → thick, fast → thin
                var u = PencilStampUniforms(prev: prev, cur: cur, halfWidth: halfW, aspect: Float(w) / Float(h))
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = layer
                rp.colorAttachments[0].loadAction = .load
                rp.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) {
                    enc.setRenderPipelineState(pipeline)
                    enc.setFragmentBytes(&u, length: MemoryLayout<PencilStampUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
                pencilPrevUV = cur
            }
        } else if !snapshot.leftPressed {
            pencilPrevUV = SIMD2(-1, -1)   // pen lifted: the next stroke starts fresh, no joining line
            pencilSmoothedUV = SIMD2(-1, -1)
            pencilAnchorUV = SIMD2(-1, -1)
        }
        return layer
    }

    /// Enable/disable drawing the live cursor into the frame (so it runs through the chain).
    /// Called from the main actor. The shared `cursorSampler` is engaged separately by the
    /// engine; this only flips whether the composite pass runs.
    func setCustomCursorEnabled(_ on: Bool) {
        cursorCompositor.enabled = on
    }

    /// Set the active cursor styling (MAOE §6) on this display's compositor. Main thread.
    func setCursorSpec(_ spec: CursorSpec) {
        cursorCompositor.spec = spec
    }

    /// MAOE §15.4: capture the next rendered frame as a `CGImage` (the styled desktop). The
    /// completion fires on the main thread. Triggers a redraw so a static desktop still captures.
    func captureNextFrame(_ completion: @escaping (CGImage?) -> Void) {
        stateLock.lock(); captureRequest = completion; stateLock.unlock()
        requestRedraw()
    }

    /// Cache the overlay's current frame (AppKit global points) for the cursor composite. Main
    /// thread.
    func setOverlayFramePoints(_ frame: CGRect) {
        stateLock.lock(); cachedFramePoints = frame; stateLock.unlock()
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
        return chain.contains { $0.isEffectivelyAnimated }
    }

    /// Store the most recent captured frame for the render loop to consume. Called
    /// on the capture queue; never blocks (no drawable, no GPU work here), so the
    /// capture queue keeps delivering frames at full rate.
    func submit(_ frame: CapturedFrame) {
        frameLock.lock()
        submitSeq += 1
        pendingFrame = frame
        pendingSeq = submitSeq
        frameLock.unlock()
    }

    /// Monotonic count of frames received from the capture queue (bumped in `submit`). The
    /// engine's post-Space-switch capture watchdog reads this to detect a stream that silently
    /// stopped delivering frames after a carry: ScreenCaptureKit can sit emitting only
    /// non-`.complete` frames (or none) without ever calling `didStopWithError`, so the normal
    /// restart path never runs and the overlay freezes on the last frame. Thread-safe.
    var capturedFrameCount: UInt64 {
        frameLock.lock(); defer { frameLock.unlock() }; return submitSeq
    }

    /// Frame/present counters for the engine's hard-freeze failsafe: `frames` = total
    /// captured frames submitted, `presents` = total presented to a drawable. When capture
    /// keeps advancing but presents stall, the render clock has died and the overlay is
    /// recreated (see `SpectraEngine.detectAndRecoverHardFreeze`). Thread-safe for `frames`;
    /// `presents` is a plain counter whose races are harmless for the coarse heuristic.
    func renderHealthSnapshot() -> (frames: UInt64, presents: UInt64) {
        frameLock.lock(); let f = submitSeq; frameLock.unlock()
        return (f, presentCount)
    }
    /// Total frames presented to a drawable (bumped on the link thread in the callback).
    private var presentCount: UInt64 = 0

    // MARK: - Frame-gated reveal (main thread)

    /// Arm a one-shot reveal that fires once `revealFreshFrameCount` freshly-captured
    /// frames have been PRESENTED after this call — i.e. once the new Space's content is
    /// actually on screen. Called on the main actor by the engine right after a Space
    /// carry + capture re-issue. Re-arming replaces any pending arm.
    func armFrameGatedReveal(_ onReveal: @escaping () -> Void) {
        frameLock.lock()
        let base = submitSeq
        frameLock.unlock()
        revealTargetSeq = base + Self.revealFreshFrameCount
        revealHandler = onReveal
    }

    /// Cancel a pending frame-gated reveal (e.g. another Space change supersedes it).
    func disarmFrameGatedReveal() {
        revealTargetSeq = .max
        revealHandler = nil
    }

    /// Fire the armed reveal if a fresh enough frame has now been presented. Main thread
    /// only (the render callback), matching `armFrameGatedReveal`.
    private func fireRevealIfReady(presentedSeq: UInt64) {
        guard revealHandler != nil, presentedSeq >= revealTargetSeq else { return }
        let handler = revealHandler
        revealHandler = nil
        revealTargetSeq = .max
        handler?()
    }

    // MARK: - Display-link lifecycle (main thread)

    /// Create the render clock (once) and attach it to the dedicated `linkThread`'s run loop
    /// (NOT the main run loop), so SwiftUI layout on main can't delay a tick. The clock is a
    /// `CAMetalDisplayLink` bound to the overlay layer: it actively drives the layer at the
    /// full display refresh (60), which a screen-tied `NSScreen.displayLink` does NOT — that
    /// follows the display's adaptive rate, which macOS throttles to ~30 for the opaque,
    /// low-motion overlay. The tradeoff is that this link stops when the overlay window is
    /// hidden/re-ordered (a Space carry), so `rebuildDisplayLink` re-creates it after a carry.
    /// The link OBJECT is created/paused/invalidated here on the main thread (thread-safe and
    /// keeps the proven Space lifecycle unchanged); only its callback runs on `linkThread`.
    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        linkThread.start(name: "com.spectra.renderlink.\(displayID)")
        guard let runLoop = linkThread.runLoop else { return }
        let link = CAMetalDisplayLink(metalLayer: overlay.metalLayer)
        link.delegate = self
        link.isPaused = true
        applyPreferredFrameRate(to: link)
        link.add(to: runLoop, forMode: .common)   // off-main — see RenderLinkThread
        linkThread.wake()                          // service the freshly-added link this cycle, not after the bounded wait
        displayLink = link
    }

    /// Re-create the render clock. A Space carry (`carryToActiveSpace`) re-orders the overlay
    /// window, which stops a `CAMetalDisplayLink` permanently; the engine calls this right
    /// after a carry so the overlay resumes painting on the new Space instead of freezing.
    func rebuildDisplayLink() {
        guard isActive else { Log.render.debug("rebuildLink id=\(self.displayID, privacy: .public) skipped (inactive)"); return }
        Log.render.debug("rebuildLink id=\(self.displayID, privacy: .public)")
        displayLink?.invalidate()
        displayLink = nil
        ensureDisplayLink()
        displayLink?.isPaused = false
        // Give the fresh link time before the watchdog re-checks (written on main, read by the
        // watchdog on main and by the callback on the link thread).
        stateLock.lock(); lastCallbackTime = CACurrentMediaTime(); stateLock.unlock()
        requestRedraw()
    }

    /// Engine-tick safety net: rebuild the render clock if it has stopped delivering
    /// callbacks while the overlay is on screen. The window-tied `CAMetalDisplayLink`
    /// silently dies on some Space carries (the carry's rebuild can race and miss); without
    /// this the overlay stays frozen on a stale frame until the user manually re-swipes.
    /// Gated on the overlay actually being visible so a legitimately-dormant link (overlay on
    /// a Space that isn't currently displayed) isn't churned, plus a cooldown.
    func restartDisplayLinkIfStalled(stallThreshold: Double = 0.75, cooldown: Double = 1.0) {
        stateLock.lock(); let active = _active; let lastCB = lastCallbackTime; stateLock.unlock()
        guard active, lastCB > 0, overlay.occlusionState.contains(.visible) else { return }
        let now = CACurrentMediaTime()
        guard now - lastCB > stallThreshold else { return }     // stalled: no callback for >threshold
        guard now - lastWatchdogRebuild > cooldown else { return }   // cooldown (main-only); short so a re-death recovers fast now that rebuilds actually take effect
        lastWatchdogRebuild = now
        Log.render.notice("Display-link watchdog restart id=\(self.displayID, privacy: .public) cbAgeMs=\(Int((now - lastCB) * 1000), privacy: .public)")
        rebuildDisplayLink()
    }

    /// Lower the render/present rate to the user's Frame Rate setting. Never raises
    /// it above `maxRenderFPS`.
    func setPreferredFrameRate(_ fps: Int) {
        stateLock.lock()
        guard fps != preferredFrameRate else { stateLock.unlock(); return }
        preferredFrameRate = fps
        stateLock.unlock()
        if let displayLink { applyPreferredFrameRate(to: displayLink) }
    }

    /// Set the global intensity multiplier (main actor). Cheap; takes effect on the
    /// next rendered frame.
    func setIntensityScale(_ scale: Float) {
        stateLock.lock(); intensityScale = scale; stateLock.unlock()
    }

    /// MAOE §5.2: keep this display rendering for `seconds` so a discrete event's decaying
    /// burst plays out, then return to idle. Callable from any thread (the link free-runs while
    /// active, so the next tick within ~16 ms picks this up — no explicit wake needed). Extends,
    /// never shortens, an existing decay window.
    nonisolated func armDecay(_ seconds: Double) {
        let deadline = CACurrentMediaTime() + max(0, seconds)
        stateLock.lock(); decayExpiresAt = max(decayExpiresAt, deadline); stateLock.unlock()
    }

    /// MAOE §5.4: record a window-lifecycle event (close/minimize/open) so its decaying burst
    /// fires at the window's last rect, and arm the decay clock. Thread-safe.
    nonisolated func emitLifecycleEvent(kind: Float, rectUV: SIMD4<Float>, dockDir: SIMD2<Float>) {
        stateLock.lock()
        lifecycleKind = kind
        lifecycleRect = rectUV
        lifecycleDockDir = dockDir
        lifecycleTime = CACurrentMediaTime()
        stateLock.unlock()
        armDecay(1.3)
    }

    /// The single effective render cap: `maxRenderFPS`, lowered by the user setting. Read on
    /// the link thread (rate cap) and the main thread, so it locks.
    private var renderFPSCap: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return preferredFrameRate > 0 ? min(Double(preferredFrameRate), maxRenderFPS) : maxRenderFPS
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

    /// Stop rendering and release resources (display removed / app shutdown).
    func teardown() {
        isActive = false           // pause the link
        displayLink?.invalidate()  // detaches from the run loop; no more callbacks
        displayLink = nil
        clearMailbox()
        // Free pooled textures + history ON the link thread, after any in-flight callback, so a
        // purge can't race a frame still encoding there; then stop the thread.
        linkThread.performSync { [weak self] in
            self?.historyTexture = nil
            self?.pool.purge()
        }
        linkThread.stop()
    }

    // MARK: - Frame rendering (link thread, via the display-link callback)

    /// Encode and present a captured frame onto `drawable` (supplied by the display-link
    /// callback). Runs on the link thread; the caller has already acquired the in-flight slot.
    /// Reads the main-published inputs (cursor snapshot, frame points, intensity) here. Returns
    /// whether the drawable was actually presented (used to gate the reveal).
    @discardableResult
    private func renderFrame(_ frame: CapturedFrame, drawable: CAMetalDrawable) -> Bool {
        let encodeStart = CACurrentMediaTime()

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            inFlight.signal()   // release the slot the caller acquired
            requestRedraw()
            report(dropped: true, cpu: 0, gpu: 0, latency: 0, passes: 0)
            return false
        }
        commandBuffer.label = "Spectra.display.\(displayID)"

        chainLock.lock()
        let snapshot = chain
        chainLock.unlock()

        stateLock.lock(); let intensity = intensityScale; let framePoints = cachedFramePoints
        let decayDeadline = decayExpiresAt; stateLock.unlock()
        let decayActive = CACurrentMediaTime() < decayDeadline

        let time = Float(CACurrentMediaTime() - startTime)
        frameCounter += 1
        let clock = FrameContext.liveClock()
        var frameContext = FrameContext(
            time: time, frameIndex: frameCounter,
            clockSeconds: clock.clockSeconds,
            year: clock.year, month: clock.month, day: clock.day,
            batteryLevel: BatteryProvider.level(),
            intensityScale: intensity)
        frameContext.decayActive = decayActive
        // Menu-bar height in UV (the standard ~24 pt strip at the top of the display), so the Noir
        // screen-wide ornate border can clear it and leave the clock/menus readable.
        if framePoints.height > 0 { frameContext.menuBarHeightUV = Float(26.0 / framePoints.height) }
        applyPointer(to: &frameContext, framePoints: framePoints)
        // Live window geometry (MAOE §5.1). Already display-local UV; lock-free read. Empty
        // unless a rect-consuming effect engaged the provider, so ordinary presets pay nothing.
        frameContext.windows = windowGeometry.snapshot(for: displayID).windows

        // Optionally draw the live cursor into the frame so it goes through the chain, using
        // the snapshot the main-actor sampler published. The composited texture (if any) is
        // released on GPU completion.
        let cursorComposite = cursorCompositor.composite(
            input: frame.texture, snapshot: cursorSampler.current(), displayFramePoints: framePoints,
            pressAge: frameContext.pressAge, into: commandBuffer, pool: pool)
        let chainInput = cursorComposite ?? frame.texture

        // Pencil draw-on-screen tool: maintain its persistent stroke layer (stamp while dragging,
        // clear on right-click) and hand it to the chain. Gated on the effect being present, so
        // every other preset pays nothing and keeps no layer.
        if snapshot.contains(where: { $0.descriptor.id == "interaction.pencilDraw" }) {
            frameContext.pencilLayer = updatePencilLayer(chainInput: chainInput, framePoints: framePoints, into: commandBuffer)
        } else if pencilLayer != nil {
            pencilLayer = nil   // released when leaving the Pencil world
        }

        let needsHistory = snapshot.contains { $0.descriptor.needsHistory }
        let result = chainRenderer.encode(
            into: commandBuffer, input: chainInput, chain: snapshot, frame: frameContext,
            history: needsHistory ? historyTexture : nil)

        // Hand this frame's output forward as next frame's history by reference (a
        // pointer swap) instead of a full-res blit copy. The output texture is kept
        // OUT of this frame's pool release so it survives into the next frame; the
        // PREVIOUS history — last read by THIS frame as the feedback input — is
        // released once this frame's GPU work completes. A retained history texture
        // never returns to the pool, so the chain renderer can't re-acquire it mid-flight.
        var transient = result.transientTextures
        var historyToRelease: MTLTexture?
        if needsHistory {
            historyToRelease = historyTexture
            historyTexture = result.outputTexture
            transient.removeAll { $0 === result.outputTexture }
        } else {
            historyTexture = nil
        }

        // Present pass: copy the chain output onto the drawable (format convert).
        let presented = presentTexture(result.outputTexture, to: drawable.texture, in: commandBuffer)

        let passes = result.passCount

        let cpuMilliseconds = (CACurrentMediaTime() - encodeStart) * 1000.0
        let captureHostTime = frame.hostTime

        // MAOE §15.4: one-press styled capture. Render the final output into a CPU-readable
        // texture and turn it into a CGImage on GPU completion.
        stateLock.lock(); let capture = captureRequest; captureRequest = nil; stateLock.unlock()
        if let capture {
            let w = result.outputTexture.width, h = result.outputTexture.height
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
            let captureTexture = context.device.makeTexture(descriptor: desc)
            if let captureTexture { _ = presentTexture(result.outputTexture, to: captureTexture, in: commandBuffer) }
            commandBuffer.addCompletedHandler { _ in
                let image = captureTexture.flatMap { Self.makeCGImage(from: $0) }
                DispatchQueue.main.async { capture(image) }
            }
        }

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
            if let historyToRelease { pool.release([historyToRelease]) }
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
        return presented
    }

    /// Ask the next display-link tick to repaint (used when a frame is dropped or
    /// deferred by the rate cap so a one-shot redraw isn't lost).
    private func requestRedraw() {
        frameLock.lock()
        needsRedraw = true
        frameLock.unlock()
    }

    /// Returns true if the drawable was actually rendered into (so it's safe to
    /// present), false if the present pipeline/encoder was unavailable.
    private func presentTexture(_ source: MTLTexture, to target: MTLTexture, in commandBuffer: MTLCommandBuffer) -> Bool {
        // Bicubic upscale when the chain rendered below native (Quality < 100% or the
        // Auto governor), so a sub-native frame stays sharp; the cheaper 1:1 present
        // otherwise (no resampling, so bicubic would only add cost for nothing).
        let fragment = source.width < target.width ? "present_upscale_fragment" : "present_fragment"
        guard let pipeline = try? shaders.pipeline(fragment: fragment, pixelFormat: target.pixelFormat) else {
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

    /// Read a `bgra8Unorm` shared texture's pixels into a `CGImage` (for the styled capture).
    private static func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        return ctx.makeImage()
    }

    private func report(dropped: Bool, cpu: Double, gpu: Double, latency: Double, passes: Int) {
        sampleHandler?(FrameSample(
            cpuMilliseconds: cpu, gpuMilliseconds: gpu, latencyMilliseconds: latency,
            passCount: passes, dropped: dropped, timestamp: CACurrentMediaTime()))
    }

    func purge() {
        linkThread.perform { [weak self] in self?.pool.purge() }
    }
}

// MARK: - CAMetalDisplayLinkDelegate

extension DisplayRenderer: CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard isActive else { return }
        // Watchdog heartbeat (keyed on callback delivery). Written here on the link thread,
        // read by the watchdog on main — guarded.
        stateLock.lock(); lastCallbackTime = CACurrentMediaTime(); stateLock.unlock()

        frameLock.lock()
        let hasNew = pendingFrame != nil
        let redraw = needsRedraw
        needsRedraw = false
        let frame: CapturedFrame?
        let frameSeq: UInt64
        if let pending = pendingFrame {
            frame = pending; frameSeq = pendingSeq
            lastFrame = pending; lastFrameSeq = pendingSeq
        } else {
            frame = lastFrame; frameSeq = lastFrameSeq
        }
        pendingFrame = nil
        frameLock.unlock()

        guard let frame else { return }                              // nothing captured yet
        // MAOE §5.2 decay gate: a discrete event (click/scroll/space/press/lifecycle) keeps the
        // frame live for its decaying burst, then we fall back to idle.
        stateLock.lock(); let decayDeadline = decayExpiresAt; stateLock.unlock()
        let decaying = CACurrentMediaTime() < decayDeadline
        guard hasNew || redraw || hasAnimatedEffect || decaying else { return }  // idle: nothing changed

        // Cap the render rate without inducing a beat. The link already fires at
        // `renderFPSCap` (preferredFrameRateRange); this wall-clock check is a backstop
        // against a panel that over-fires (e.g. ProMotion ignoring the max hint)
        // re-dirtying the captured scene into a compositor feedback loop. The threshold is
        // one interval MINUS a 1/5 tolerance, not a strict `1/cap`: at exactly the cap a
        // tick lands ~one interval after the last render and sub-frame jitter would push it
        // a hair under a strict threshold, deferring to the next tick and HALVING the rate
        // to ~30. The tolerance absorbs that jitter while still deferring a genuine over-fire.
        let now = CACurrentMediaTime()
        let interval = 1.0 / renderFPSCap
        if now - lastRenderHostTime < interval - interval * 0.2 {
            if hasNew || redraw { requestRedraw() }
            return
        }
        // Gate on a free in-flight slot before taking the link's drawable, so we never hold more
        // than `maxInFlight` drawables; the encode signals the slot back on GPU completion.
        guard inFlight.wait(timeout: .now()) == .success else {
            if hasNew || redraw { requestRedraw() }
            return
        }
        lastRenderHostTime = now

        // This callback already runs on the link thread (off the main run loop), so encode +
        // present directly here. `renderFrame` reads the main-published inputs (cursor snapshot,
        // cached frame points, intensity, battery) itself. The drawable comes from the link.
        let presented = renderFrame(frame, drawable: update.drawable)
        if presented { presentCount &+= 1 }
        // Fire the reveal only on a genuinely-new captured frame that actually reached the
        // drawable (never on a stale redraw). It touches NSWindow, so hop to the main thread.
        if presented, hasNew {
            DispatchQueue.main.async { [weak self] in self?.fireRevealIfReady(presentedSeq: frameSeq) }
        }
    }
}
