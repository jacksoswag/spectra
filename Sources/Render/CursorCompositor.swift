import AppKit
import Metal
import QuartzCore

/// Composites the live system cursor onto a captured frame at the live mouse position, so the
/// cursor runs through the effect chain (rather than mirrored late through the capture, which
/// lags).
///
/// Stateless and thread-agnostic: it consumes an immutable `CursorSampler.Snapshot` (sprite +
/// position, sampled on the main thread by `CursorSampler`) and the overlay's cached frame
/// rectangle, and encodes the GPU pass. It is called from the render (link) thread and touches
/// no AppKit, so the cursor sampling and the GPU composite are cleanly split across threads.
final class CursorCompositor {
    /// Toggled by the coordinator from the cursor setting (main thread). Mirrors the sampler's
    /// enabled state so the renderer can early-out without reading a snapshot.
    var enabled = false
    /// The active cursor styling (MAOE §6). Set from the main actor; read on the link thread.
    /// Plain assignment is safe: a torn read at worst styles one frame with a stale spec.
    var spec: CursorSpec = .systemDefault

    private let shaders: ShaderLibrary

    /// CPU mirror of `CursorUniforms` in Cursor.metal — identical field order + padding, so the
    /// 48-byte buffer is read correctly at the Swift/Metal boundary.
    private struct CursorUniforms {
        var rect: SIMD4<Float>
        var styleIndex: Int32
        var intensity: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var tint: SIMD4<Float>
    }

    init(shaders: ShaderLibrary) {
        self.shaders = shaders
    }

    /// The shader (styleIndex, tint) for a cursor style. Sprite styles ride passthrough; their
    /// art is substituted upstream in the sampler.
    private static func restyle(_ style: CursorStyle) -> (index: Int32, tint: SIMD4<Float>) {
        switch style {
        // Print Art's woodblock pointer adapts: it lifts toward this warm off-white over low-contrast
        // (dark/similar) backgrounds so it never vanishes. `tint.a` caps the lift strength.
        case .sprite(.printRoof): return (4, SIMD4(0.96, 0.92, 0.74, 1.0))
        case .system, .sprite, .customImage: return (0, SIMD4(0, 0, 0, 0))
        case .neonCyan: return (1, SIMD4(0.25, 1.0, 1.0, 1.0))
        case .pixelGreen: return (2, SIMD4(0.2, 1.0, 0.35, 0.9))
        case .warmTint: return (3, SIMD4(1.0, 0.82, 0.6, 0.7))
        }
    }

    /// If enabled and the pointer is over `frame`, return a new pool texture holding `input`
    /// with the cursor drawn on top; otherwise nil (use `input` unchanged). The returned texture
    /// must be released by the caller once the GPU completes the command buffer.
    func composite(input: MTLTexture, snapshot: CursorSampler.Snapshot,
                   displayFramePoints frame: CGRect, pressAge: Float = 999,
                   into commandBuffer: MTLCommandBuffer, pool: TexturePool) -> MTLTexture? {
        guard enabled, frame.width > 0, frame.height > 0 else { return nil }
        guard let cursorTexture = snapshot.texture else { return nil }
        let mouse = snapshot.position
        guard frame.contains(mouse) else { return nil }      // cursor is on another display

        // Press depression (MAOE §6): a sprite cursor with `pressAnim` shrinks slightly around
        // its hotspot while a button is held, easing in over ~80 ms. Scaling both size and
        // hotspot by the same factor keeps the visual tip pinned to the real pointer.
        var hotSpot = snapshot.hotSpot
        var sizePoints = snapshot.sizePoints
        if spec.pressAnim, pressAge < 0.9 {
            let ease = min(1, pressAge / 0.08)
            let depress = CGFloat(1 - 0.10 * ease)
            sizePoints = CGSize(width: sizePoints.width * depress, height: sizePoints.height * depress)
            hotSpot = CGPoint(x: hotSpot.x * depress, y: hotSpot.y * depress)
        }

        let inputW = CGFloat(input.width)
        let inputH = CGFloat(input.height)
        // Input pixels per display point (folds in backing scale and any adaptive downscale).
        let sx = inputW / frame.width
        let sy = inputH / frame.height
        // Mouse position within the display, converted to a top-left pixel origin.
        let relX = mouse.x - frame.minX
        let topY = frame.height - (mouse.y - frame.minY)
        let rectX = (relX - hotSpot.x) * sx
        let rectY = (topY - hotSpot.y) * sy
        let rectW = sizePoints.width * sx
        let rectH = sizePoints.height * sy

        let (styleIndex, tint) = Self.restyle(spec.style)
        var uniforms = CursorUniforms(
            rect: SIMD4<Float>(
                Float(rectX / inputW), Float(rectY / inputH),
                Float((rectX + rectW) / inputW), Float((rectY + rectH) / inputH)),
            styleIndex: styleIndex,
            intensity: spec.intensity.scalar,
            tint: tint)

        guard let pipeline = try? shaders.pipeline(
            fragment: "fx_cursor_composite", pixelFormat: MetalContext.workingPixelFormat) else {
            return nil
        }
        let target = pool.acquire(width: input.width, height: input.height)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            pool.release(target)
            return nil
        }
        encoder.label = "Spectra.cursor.\(input.width)x\(input.height)"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentTexture(cursorTexture, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CursorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return target
    }
}
