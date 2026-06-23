import Foundation
import Metal
import simd
import CoreGraphics
import ImageIO

/// Per-frame context shared by every pass in a chain.
struct FrameContext {
    /// Seconds since the engine started (drives animated effects).
    var time: Float
    /// Monotonic frame counter.
    var frameIndex: Float
    /// Seconds since local midnight (wall clock) for the live REC-OSD timecode.
    var clockSeconds: Float = 0
    /// Today's calendar date for the live REC-OSD date stamp.
    var year: Float = 1998
    var month: Float = 7
    var day: Float = 14
    /// Host battery fraction (0...1) for the live REC-OSD battery icon. Defaults to
    /// full so callers that don't sample it (e.g. the preview) read a full bar.
    var batteryLevel: Float = 1.0
    /// Global intensity multiplier applied to every effect's universal strength
    /// (the master "intensity" slider). 1.0 = render each effect at its authored
    /// strength; the engine derives this linearly from the user's setting (100% → 1.0×).
    var intensityScale: Float = 1.0
    /// Menu-bar height in display UV (0 when unknown / no menu bar). The Noir screen-wide ornate
    /// border reads this (injected into slot 7) and clears that top strip so the clock/menus stay
    /// readable.
    var menuBarHeightUV: Float = 0

    // MARK: Interactive pointer state
    //
    // Live mouse state for the interactive effects (water splash, bubble pop), already
    // converted to THIS display's UV (top-left origin, matching `in.uv`) by the renderer.
    // Populated only while a pointer effect is in the chain; otherwise inert — `pressActive`
    // 0 and the ages large — so the effects render their ambient behaviour and nothing more.

    /// Left button currently held (1) or not (0).
    var pressActive: Float = 0
    /// Seconds since the last release; large when none recent (drives the release collapse).
    var releaseAge: Float = 999
    /// UV of the last mouse-down (the crown origin and the click-to-pop hit point). Off-canvas
    /// default so a chain with no real click never bursts a bubble at the origin.
    var clickPoint: SIMD2<Float> = SIMD2(-1, -1)
    /// Seconds since the last mouse-down; large when none yet.
    var clickAge: Float = 999
    /// Recent pointer path in UV, newest first (the dragged-water rope); ≤ trailCount entries.
    var pointerTrail: [SIMD2<Float>] = []
    var pointerTrailCount: Float = 0
    /// Persistent draw-on-screen accumulation layer for the Pencil-Sketch draw tool (red channel =
    /// stroke mask). Managed by `DisplayRenderer` (stamped while the left button drags, cleared on a
    /// right-click); bound for `fx_int_pencilDraw`. nil for every other chain.
    var pencilLayer: MTLTexture? = nil

    // MARK: Window geometry (MAOE §5.1)
    //
    // Live per-window rectangles (display-local top-left UV), populated only while a
    // rect-consuming effect (chrome §12, generative §15.2) is in the chain; otherwise empty,
    // so the geometry buffer is never bound and ordinary effects pay nothing.
    var windows: [WindowGeometryProvider.Window] = []
    var windowCount: Int { windows.count }

    // MARK: Discrete events (MAOE §5.2)
    //
    // Seconds since each event (large sentinel when none recent), injected into the event
    // uniform block for the event-driven interaction effects (§7). Populated only while an
    // event-consuming effect is in the chain; inert otherwise.
    /// Seconds since the last scroll-wheel event, and that event's delta.
    var scrollAge: Float = 999
    var scrollDelta: SIMD2<Float> = .zero
    /// Seconds since the last Space switch settled (drives space-transition signatures).
    var spaceAge: Float = 999
    /// Seconds the current press has been held (any button); large sentinel when not pressed.
    var pressAge: Float = 999
    /// Most recent window-lifecycle event (§5.4): age, kind (0 none/1 opened/2 closed/3
    /// minimized), the window's last rect in UV, and the Dock direction for a minimize.
    var lifecycleAge: Float = 999
    var lifecycleKind: Float = 0
    var lifecycleRect: SIMD4<Float> = .zero
    var dockDirection: SIMD2<Float> = .zero
    /// Current pointer position (this display's UV; (-1,-1) when on another display), its
    /// normalized speed (UV/sec), and seconds since the last significant move — for the
    /// movement-reactive effects (light leak, speed lines, CMYK shift).
    var currentPointer: SIMD2<Float> = SIMD2(-1, -1)
    var pointerSpeed: Float = 0
    var moveAge: Float = 999
    /// Whether the §5.2 decay render gate is currently active (a discrete event is within its
    /// decay window). When false, the renderer skips event-driven passes (§10) — they would
    /// only render `base` — reclaiming their cost inside an otherwise-animated world.
    var decayActive: Bool = false

    // MARK: Ambient inputs (MAOE §15.1) — global signals injected at slots 64+ for
    // ambient-aware effects (audio-reactive / keyboard-reactive). Inert (zeros / large age)
    // unless the feature is enabled and the world opts in.
    /// Overall audio level (0…1) and three coarse bands (bass / mid / treble), 0…1 each.
    var audioLevel: Float = 0
    var audioBands: SIMD3<Float> = .zero
    /// Seconds since the last keystroke (large sentinel when none) and a 0…1 glyph seed for it.
    var keyAge: Float = 999
    var keyChar: Float = 0

    /// Sample the system wall clock for the live REC OSD: seconds since local
    /// midnight plus today's year/month/day. Cheap (microseconds); called once per
    /// rendered frame, not per pass.
    static func liveClock(now: Date = Date()) -> (clockSeconds: Float, year: Float, month: Float, day: Float) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let secs = Float((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0))
        return (secs, Float(c.year ?? 1998), Float(c.month ?? 7), Float(c.day ?? 14))
    }
}

/// The result of encoding an effect chain into a command buffer.
struct ChainRenderResult {
    /// The final texture of the chain (equals `input` when the chain is empty).
    let outputTexture: MTLTexture
    /// Pool textures used as intermediates; release these on GPU completion.
    let transientTextures: [MTLTexture]
    /// Number of GPU passes encoded (for profiling).
    let passCount: Int
}

/// Encodes an ordered list of resolved effects into render passes, ping-ponging
/// pooled textures. Stateless across frames apart from the injected pool, so a
/// single instance can serve overlay rendering and the live preview.
final class EffectChainRenderer {
    private let context: MetalContext
    private let shaders: ShaderLibrary
    private let pool: TexturePool

    init(context: MetalContext, shaders: ShaderLibrary, pool: TexturePool) {
        self.context = context
        self.shaders = shaders
        self.pool = pool
    }

    /// The three bundled comic burst sprites for `fx_int_powSprite` (§7.1) — POW / BANG / POP —
    /// loaded once and bound at fragment texture indices 8 / 12 / 13. The shader picks one per click
    /// (hashed off the click position) so each click pops a different word. nil entries fall back to
    /// the POW sprite, and an all-nil set no-ops the effect gracefully.
    private lazy var powSpriteTexture: MTLTexture? =
        Self.loadBundledTexture("pow-sprite", subdirectory: "InteractionSprites", device: context.device)
    private lazy var bangSpriteTexture: MTLTexture? =
        Self.loadBundledTexture("bang-sprite", subdirectory: "InteractionSprites", device: context.device)
    private lazy var popSpriteTexture: MTLTexture? =
        Self.loadBundledTexture("pop-sprite", subdirectory: "InteractionSprites", device: context.device)
    static let powSpriteTextureIndex = 8
    static let bangSpriteTextureIndex = 12
    static let popSpriteTextureIndex = 13
    /// Fragment texture index at which the Pencil draw-layer is bound for `fx_int_pencilDraw`.
    static let pencilLayerTextureIndex = 14

    /// Bundled ornate corner flourish for `fx_chrome_spriteBorder` (Noir art-nouveau frame), bound
    /// at fragment texture index 11. nil if missing (the pass then draws only its thin edge rule).
    private lazy var borderSpriteTexture: MTLTexture? =
        Self.loadBundledTexture("ornate-corner", subdirectory: "BorderSprites", device: context.device)
    static let borderSpriteTextureIndex = 11

    /// Load a bundled `@2x` PNG into a premultiplied rgba8 texture.
    private static func loadBundledTexture(_ name: String, subdirectory: String, device: MTLDevice) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: name + "@2x", withExtension: "png")
                ?? Bundle.main.url(forResource: name + "@2x", withExtension: "png", subdirectory: subdirectory),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = cg.width, h = cg.height, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead; desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bpr)
        }
        return tex
    }

    /// Base parameter slot of the injected pointer block. Sits above any pointer effect's own
    /// params (bubbles 0…5, splash 0…4), so the block never clobbers them: 16 clickX, 17 clickY,
    /// 18 clickAge, 19 pressActive, 20 releaseAge, 21 trailCount, then 22… trail UV pairs.
    static let pointerSlotBase = 16

    /// First free slot after the pointer/trail block — the event block's base. Recomputed from
    /// `trailCount` (16 + 6 named + trailCount×2 = 46 today) so changing the trail length shifts
    /// it automatically rather than silently overlapping. Event block layout:
    /// 46 scrollAge, 47/48 scrollDelta, 49 spaceAge, 50 pressAge, 51 lifecycleAge,
    /// 52 lifecycleKind, 53…56 lifecycleRect, 57/58 dockDirection.
    static let eventSlotBase = pointerSlotBase + 6 + PointerInputSampler.trailCount * 2

    /// Inject the live pointer state into a pointer effect's reserved high slots, after
    /// `writeParameters` (which clears all 64 slots). Gated on the pass's `consumesPointer`
    /// flag (set at the descriptor authoring site); a no-op for every other pass.
    private func injectPointer(into uniforms: inout SpectraUniforms, pass: EffectPass, frame: FrameContext) {
        guard pass.consumesPointer else { return }
        let base = Self.pointerSlotBase
        uniforms.setParam(base + 0, frame.clickPoint.x)
        uniforms.setParam(base + 1, frame.clickPoint.y)
        uniforms.setParam(base + 2, frame.clickAge)
        uniforms.setParam(base + 3, frame.pressActive)
        uniforms.setParam(base + 4, frame.releaseAge)
        uniforms.setParam(base + 5, frame.pointerTrailCount)
        var slot = base + 6
        // The trail rides in a reused fixed buffer; only the first `pointerTrailCount` entries
        // are valid (the rest are stale), so read by count rather than the buffer length.
        let count = min(Int(frame.pointerTrailCount), frame.pointerTrail.count)
        for i in 0..<count {
            let point = frame.pointerTrail[i]
            uniforms.setParam(slot, point.x)
            uniforms.setParam(slot + 1, point.y)
            slot += 2
        }
    }

    /// Base slot of the ambient global block (above the 0–63 effect/injection range).
    /// 64 audioLevel, 65/66/67 audioBands, 68 keyAge, 69 keyChar.
    private static let ambientSlotBase = 64

    /// Inject the ambient global block (audio + keyboard, MAOE §15.1). Gated on the pass's
    /// `consumesAmbient` flag (set at the descriptor authoring site); a no-op otherwise.
    private func injectAmbient(into uniforms: inout SpectraUniforms, pass: EffectPass, frame: FrameContext) {
        guard pass.consumesAmbient else { return }
        let base = Self.ambientSlotBase
        uniforms.setParam(base + 0, frame.audioLevel)
        uniforms.setParam(base + 1, frame.audioBands.x)
        uniforms.setParam(base + 2, frame.audioBands.y)
        uniforms.setParam(base + 3, frame.audioBands.z)
        uniforms.setParam(base + 4, frame.keyAge)
        uniforms.setParam(base + 5, frame.keyChar)
    }

    /// Inject the live event block (scroll / space / press / lifecycle), after `writeParameters`.
    /// Gated on the pass's `consumesEvent` flag (set at the descriptor authoring site); a no-op
    /// otherwise. Disjoint from the pointer block, so a pass may set both flags.
    private func injectEvent(into uniforms: inout SpectraUniforms, pass: EffectPass, frame: FrameContext) {
        guard pass.consumesEvent else { return }
        let base = Self.eventSlotBase
        uniforms.setParam(base + 0, frame.scrollAge)
        uniforms.setParam(base + 1, frame.scrollDelta.x)
        uniforms.setParam(base + 2, frame.scrollDelta.y)
        uniforms.setParam(base + 3, frame.spaceAge)
        uniforms.setParam(base + 4, frame.pressAge)
        uniforms.setParam(base + 5, frame.lifecycleAge)
        uniforms.setParam(base + 6, frame.lifecycleKind)
        uniforms.setParam(base + 7, frame.lifecycleRect.x)
        uniforms.setParam(base + 8, frame.lifecycleRect.y)
        uniforms.setParam(base + 9, frame.lifecycleRect.z)
        uniforms.setParam(base + 10, frame.lifecycleRect.w)
        uniforms.setParam(base + 11, frame.dockDirection.x)
        uniforms.setParam(base + 12, frame.dockDirection.y)
        uniforms.setParam(base + 13, frame.currentPointer.x)
        uniforms.setParam(base + 14, frame.currentPointer.y)
        uniforms.setParam(base + 15, frame.pointerSpeed)
        uniforms.setParam(base + 16, frame.moveAge)
    }

    /// Fragment texture index at which the previous frame's output is bound for
    /// history/feedback effects (datamosh, frame hold). Effects that don't use it
    /// simply ignore the binding.
    static let historyTextureIndex = 10

    /// Fragment/compute texture index at which a pass's `tapPass` (an earlier pass's retained
    /// output) is bound. Chosen above the usual aux range and below history.
    static let tappedTextureIndex = 9

    /// Encode the chain. The caller owns presenting `outputTexture` and must
    /// release `transientTextures` once the command buffer completes. `history`
    /// is the previous frame's processed output (bound at `historyTextureIndex`);
    /// when nil the input is bound instead so feedback effects degrade to a no-op.
    func encode(
        into commandBuffer: MTLCommandBuffer,
        input: MTLTexture,
        chain: [ResolvedEffect],
        frame: FrameContext,
        history: MTLTexture? = nil
    ) -> ChainRenderResult {
        let width = input.width
        let height = input.height
        guard !chain.isEmpty else {
            return ChainRenderResult(outputTexture: input, transientTextures: [], passCount: 0)
        }

        // `obtained` is every pool texture used this frame; it is released back to
        // the pool only on GPU completion (the textures are still in flight). To
        // keep the live working set small (≈3 textures, not one-per-pass), consumed
        // intermediates are pushed onto `reusable` and handed back out within this
        // same command buffer — safe because render passes execute in encode order.
        var obtained: [MTLTexture] = []
        var reusable: [MTLTexture] = []
        var passCount = 0

        // Live window-geometry buffer (MAOE §5.1), packed once per frame and bound at
        // fragment/compute buffer index 2 only for passes that declare `requiresWindowRects`.
        // Lazy: an empty window list still yields a valid zero-count buffer so a chrome shader
        // reads "no windows" rather than garbage.
        var packedWindows: [Float]?
        func windowBuffer() -> [Float] {
            if let packedWindows { return packedWindows }
            let p = WindowGeometryUniforms.pack(frame.windows)
            packedWindows = p
            return p
        }

        func obtain(_ w: Int, _ h: Int) -> MTLTexture {
            if let index = reusable.firstIndex(where: { $0.width == w && $0.height == h }) {
                return reusable.remove(at: index)
            }
            let texture = pool.acquire(width: w, height: h)
            obtained.append(texture)
            return texture
        }

        var current = input

        // Predither: copy the (typically 8-bit) source into the 16-bit working
        // space with ~1 LSB triangular noise. Later effects that stretch tones
        // (brightness, contrast, temperature, bloom) then smear that noise into
        // the gaps between source levels instead of exposing hard bands.
        if let preditherPipeline = try? shaders.pipeline(
            fragment: "present_fragment", pixelFormat: MetalContext.workingPixelFormat) {
            let dithered = obtain(width, height)
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = dithered
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                encoder.setRenderPipelineState(preditherPipeline)
                encoder.setFragmentTexture(input, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            current = dithered
        }

        for effect in chain {
            // MAOE §10: skip an event-driven effect while the decay gate is idle — it would
            // only return `base`, so skipping reclaims its full-screen pass inside an animated
            // world. Continuous / graded effects (triggerKind nil or .continuous) always run.
            if let trigger = effect.descriptor.triggerKind, trigger.isEventDriven, !frame.decayActive {
                continue
            }
            let effectInput = current
            var passSource = current
            var previousTarget: MTLTexture?
            // Pass outputs that a later pass taps must not be recycled mid-effect; track them
            // and the index of the output currently held in `previousTarget`. Set is derived
            // once at resolve time (`ResolvedEffect.tappedIndices`), not rebuilt per frame.
            let tappedIndices = effect.tappedIndices
            var passOutputs: [Int: MTLTexture] = [:]
            var previousTargetIndex: Int?

            for (passIndex, pass) in effect.descriptor.passes.enumerated() {
                // A pass can drive its target scale from a parameter slot (a runtime
                // "Render Scale" slider), falling back to the authored `scale` when unset.
                var passScale = pass.scale
                if let slot = pass.scaleParam {
                    // Read the one parameter float directly instead of materialising a full
                    // SpectraUniforms via writeParameters (which clears 80 slots and allocates a
                    // [Float] per parameter) just to probe a single value each frame.
                    let floats = effect.parameterFloats()
                    let v = slot < floats.count ? floats[slot] : 0
                    if v > 0.01 { passScale = max(0.1, min(1.0, v)) }
                }
                let targetWidth = max(1, Int((Float(width) * passScale).rounded()))
                let targetHeight = max(1, Int((Float(height) * passScale).rounded()))

                // Compute pass: dispatch a kernel that writes the output texture directly.
                // Bindings mirror the render path (src=0, orig=1, aux=2+, history=10) plus
                // the writable output at texture(11).
                if pass.isCompute {
                    let computePipeline: MTLComputePipelineState
                    do {
                        computePipeline = try shaders.computePipeline(
                            pass.fragmentFunction, library: effect.customLibrary)
                    } catch {
                        Log.render.error("Skipping compute pass '\(pass.fragmentFunction)': \(error.localizedDescription)")
                        continue
                    }
                    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                        Log.render.error("Skipping compute pass '\(pass.fragmentFunction)': could not create compute encoder")
                        continue
                    }
                    let target = obtain(targetWidth, targetHeight)
                    encoder.label = "\(effect.descriptor.id)#\(passIndex) (compute)"
                    encoder.setComputePipelineState(computePipeline)

                    // Uniforms live on zero-initialised stack scratch for this pass (no heap
                    // allocation per GPU pass); `setBytes` copies them into the encoder.
                    withUnsafeTemporaryAllocation(of: Float.self, capacity: SpectraUniforms.floatCount) { scratch in
                        scratch.initialize(repeating: 0)
                        var uniforms = SpectraUniforms(storage: scratch)
                        uniforms.resolution = SIMD2(Float(targetWidth), Float(targetHeight))
                        uniforms.time = frame.time
                        uniforms.frameIndex = frame.frameIndex
                        uniforms.clockSeconds = frame.clockSeconds
                        uniforms.passIndex = Float(passIndex)
                        uniforms.passScale = passScale
                        uniforms.direction = pass.direction
                        effect.writeUniversal(into: &uniforms)
                        uniforms.strength *= frame.intensityScale
                        effect.writeParameters(into: &uniforms)
                        injectPointer(into: &uniforms, pass: pass, frame: frame)
                        injectEvent(into: &uniforms, pass: pass, frame: frame)
                        injectAmbient(into: &uniforms, pass: pass, frame: frame)

                        encoder.setTexture(passSource, index: 0)
                        encoder.setTexture(effectInput, index: 1)
                        for (auxIndex, auxTexture) in effect.auxTextures.enumerated() {
                            encoder.setTexture(auxTexture, index: 2 + auxIndex)
                        }
                        encoder.setTexture(history ?? input, index: Self.historyTextureIndex)
                        if let tap = pass.tapPass, let tapTex = passOutputs[tap] {
                            encoder.setTexture(tapTex, index: Self.tappedTextureIndex)
                        }
                        if pass.requiresWindowRects {
                            windowBuffer().withUnsafeBytes { raw in
                                encoder.setBytes(raw.baseAddress!, length: WindowGeometryUniforms.byteCount, index: 2)
                            }
                        }
                        encoder.setTexture(target, index: 11)
                        uniforms.withUnsafeBytes { raw in
                            encoder.setBytes(raw.baseAddress!, length: SpectraUniforms.byteCount, index: 0)
                        }
                    }
                    let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
                    let groups = MTLSize(width: (targetWidth + 15) / 16,
                                         height: (targetHeight + 15) / 16, depth: 1)
                    encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroup)
                    encoder.endEncoding()

                    if let previousTarget, !(previousTargetIndex.map { tappedIndices.contains($0) } ?? false) {
                        reusable.append(previousTarget)
                    }
                    passOutputs[passIndex] = target
                    previousTarget = target
                    previousTargetIndex = passIndex
                    passSource = target
                    passCount += 1
                    continue
                }

                let pipeline: MTLRenderPipelineState
                do {
                    pipeline = try shaders.pipeline(
                        fragment: pass.fragmentFunction,
                        pixelFormat: MetalContext.workingPixelFormat,
                        library: effect.customLibrary)
                } catch {
                    Log.render.error("Skipping pass '\(pass.fragmentFunction)': \(error.localizedDescription)")
                    continue
                }

                let target = obtain(targetWidth, targetHeight)

                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = target
                descriptor.colorAttachments[0].loadAction = .dontCare
                descriptor.colorAttachments[0].storeAction = .store

                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                    continue
                }
                encoder.label = "\(effect.descriptor.id)#\(passIndex)"
                encoder.setRenderPipelineState(pipeline)

                // Uniforms live on zero-initialised stack scratch for this pass (no heap
                // allocation per GPU pass); `setFragmentBytes` copies them into the encoder.
                withUnsafeTemporaryAllocation(of: Float.self, capacity: SpectraUniforms.floatCount) { scratch in
                    scratch.initialize(repeating: 0)
                    var uniforms = SpectraUniforms(storage: scratch)
                    uniforms.resolution = SIMD2(Float(targetWidth), Float(targetHeight))
                    uniforms.time = frame.time
                    uniforms.frameIndex = frame.frameIndex
                    uniforms.clockSeconds = frame.clockSeconds
                    uniforms.passIndex = Float(passIndex)
                    uniforms.passScale = pass.scale
                    uniforms.direction = pass.direction
                    effect.writeUniversal(into: &uniforms)
                    // Fold in the global intensity multiplier. Scaling the universal
                    // strength turns one slider into "overall shader strength": for
                    // cross-faded effects it pushes the processed/original mix (the
                    // composite lets strength exceed 1 so presets authored at full
                    // strength still gain headroom); for geometric effects, which read
                    // strength directly, it scales the displacement.
                    uniforms.strength *= frame.intensityScale
                    effect.writeParameters(into: &uniforms)
                    injectPointer(into: &uniforms, pass: pass, frame: frame)
                    injectEvent(into: &uniforms, pass: pass, frame: frame)
                    injectAmbient(into: &uniforms, pass: pass, frame: frame)
                    // Noir's ornate border (params 0..6) reads the menu-bar height from the free slot 7
                    // so it can clear the menu-bar strip; harmless for any other pass.
                    if pass.injectsMenuBarHeight {
                        uniforms.setParam(7, frame.menuBarHeightUV)
                    }
                    // REC OSD system-injected values. Runs for every recOSD pass.
                    if pass.injectsRecOSD {
                        // recOSD declares params 0..10, leaving slot 11 free for a
                        // system-injected value — used here to feed the real battery
                        // fraction to the icon. Unconditional (not gated on liveClock) so
                        // the bar is accurate regardless of the live-date toggle.
                        uniforms.setParam(11, frame.batteryLevel)
                        // Live mode (param 10): replace the static year/month/day params
                        // (5/6/7) with today's date. The timecode reads u.clockSeconds
                        // directly in the shader.
                        if uniforms.param(10) > 0.5 {
                            uniforms.setParam(5, frame.year)
                            uniforms.setParam(6, frame.month)
                            uniforms.setParam(7, frame.day)
                        }
                    }

                    encoder.setFragmentTexture(passSource, index: 0)
                    encoder.setFragmentTexture(effectInput, index: 1)
                    for (auxIndex, auxTexture) in effect.auxTextures.enumerated() {
                        encoder.setFragmentTexture(auxTexture, index: 2 + auxIndex)
                    }
                    encoder.setFragmentTexture(history ?? input, index: Self.historyTextureIndex)
                    if let tap = pass.tapPass, let tapTex = passOutputs[tap] {
                        encoder.setFragmentTexture(tapTex, index: Self.tappedTextureIndex)
                    }
                    uniforms.withUnsafeBytes { raw in
                        encoder.setFragmentBytes(raw.baseAddress!, length: SpectraUniforms.byteCount, index: 0)
                    }
                }
                if pass.requiresWindowRects {
                    windowBuffer().withUnsafeBytes { raw in
                        encoder.setFragmentBytes(raw.baseAddress!, length: WindowGeometryUniforms.byteCount, index: 2)
                    }
                }
                if pass.fragmentFunction == "fx_int_powSprite", let pow = powSpriteTexture {
                    // Bind all three burst sprites; the shader selects per click. Missing variants
                    // fall back to POW so every bound slot is valid.
                    encoder.setFragmentTexture(pow, index: Self.powSpriteTextureIndex)
                    encoder.setFragmentTexture(bangSpriteTexture ?? pow, index: Self.bangSpriteTextureIndex)
                    encoder.setFragmentTexture(popSpriteTexture ?? pow, index: Self.popSpriteTextureIndex)
                }
                if pass.fragmentFunction == "fx_chrome_spriteBorder", let tex = borderSpriteTexture {
                    encoder.setFragmentTexture(tex, index: Self.borderSpriteTextureIndex)
                }
                if pass.fragmentFunction == "fx_int_pencilDraw", let tex = frame.pencilLayer {
                    encoder.setFragmentTexture(tex, index: Self.pencilLayerTextureIndex)
                }
                // Fused colour pass: its run of ops rides in a second buffer. Each
                // op carries its own strength, so the global intensity is folded in
                // per-op here (only when it isn't the 1.0 identity, to avoid copying
                // the buffer every frame at the default).
                if let fusedOps = effect.fusedOps {
                    var ops = fusedOps
                    if frame.intensityScale != 1.0 {
                        let count = min(Int(ops[0]), ColorFusion.maxOps)
                        for i in 0..<count { ops[1 + i * ColorFusion.stride + 1] *= frame.intensityScale }
                    }
                    ops.withUnsafeBytes { raw in
                        encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
                    }
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()

                // The just-consumed intermediate target is free to reuse this frame — unless a
                // later pass taps it (then keep it alive; it's released at frame end).
                if let previousTarget, !(previousTargetIndex.map { tappedIndices.contains($0) } ?? false) {
                    reusable.append(previousTarget)
                }
                passOutputs[passIndex] = target
                previousTarget = target
                previousTargetIndex = passIndex
                passSource = target
                passCount += 1
            }

            // This effect's input (the previous effect's output) is now spent.
            if effectInput !== input { reusable.append(effectInput) }
            current = passSource
        }

        return ChainRenderResult(outputTexture: current, transientTextures: obtained, passCount: passCount)
    }
}
