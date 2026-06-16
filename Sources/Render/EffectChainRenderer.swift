import Foundation
import Metal
import simd

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

    /// Fragment texture index at which the previous frame's output is bound for
    /// history/feedback effects (datamosh, frame hold). Effects that don't use it
    /// simply ignore the binding.
    static let historyTextureIndex = 10

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
            let effectInput = current
            var passSource = current
            var previousTarget: MTLTexture?

            for (passIndex, pass) in effect.descriptor.passes.enumerated() {
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

                let targetWidth = max(1, Int((Float(width) * pass.scale).rounded()))
                let targetHeight = max(1, Int((Float(height) * pass.scale).rounded()))
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

                var uniforms = SpectraUniforms()
                uniforms.resolution = SIMD2(Float(targetWidth), Float(targetHeight))
                uniforms.time = frame.time
                uniforms.frameIndex = frame.frameIndex
                uniforms.clockSeconds = frame.clockSeconds
                uniforms.passIndex = Float(passIndex)
                uniforms.passScale = pass.scale
                uniforms.direction = pass.direction
                effect.writeUniversal(into: &uniforms)
                effect.writeParameters(into: &uniforms)
                // REC OSD system-injected values. Runs for every recOSD pass.
                if pass.fragmentFunction == "fx_cam_recOSD" {
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
                uniforms.withUnsafeBytes { raw in
                    encoder.setFragmentBytes(raw.baseAddress!, length: SpectraUniforms.byteCount, index: 0)
                }
                // Fused colour pass: its run of ops rides in a second buffer.
                if let fusedOps = effect.fusedOps {
                    fusedOps.withUnsafeBytes { raw in
                        encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
                    }
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()

                // The just-consumed intermediate target is free to reuse this frame.
                if let previousTarget { reusable.append(previousTarget) }
                previousTarget = target
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
