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
    /// Toggled by the coordinator from the "Custom cursor" setting (main thread). Mirrors the
    /// sampler's enabled state so the renderer can early-out without reading a snapshot.
    var enabled = false

    private let shaders: ShaderLibrary

    private struct CursorUniforms { var rect: SIMD4<Float> }

    init(shaders: ShaderLibrary) {
        self.shaders = shaders
    }

    /// If enabled and the pointer is over `frame`, return a new pool texture holding `input`
    /// with the cursor drawn on top; otherwise nil (use `input` unchanged). The returned texture
    /// must be released by the caller once the GPU completes the command buffer.
    func composite(input: MTLTexture, snapshot: CursorSampler.Snapshot,
                   displayFramePoints frame: CGRect,
                   into commandBuffer: MTLCommandBuffer, pool: TexturePool) -> MTLTexture? {
        guard enabled, frame.width > 0, frame.height > 0 else { return nil }
        guard let cursorTexture = snapshot.texture else { return nil }
        let mouse = snapshot.position
        guard frame.contains(mouse) else { return nil }      // cursor is on another display

        let inputW = CGFloat(input.width)
        let inputH = CGFloat(input.height)
        // Input pixels per display point (folds in backing scale and any adaptive downscale).
        let sx = inputW / frame.width
        let sy = inputH / frame.height
        // Mouse position within the display, converted to a top-left pixel origin.
        let relX = mouse.x - frame.minX
        let topY = frame.height - (mouse.y - frame.minY)
        let rectX = (relX - snapshot.hotSpot.x) * sx
        let rectY = (topY - snapshot.hotSpot.y) * sy
        let rectW = snapshot.sizePoints.width * sx
        let rectH = snapshot.sizePoints.height * sy

        var uniforms = CursorUniforms(rect: SIMD4<Float>(
            Float(rectX / inputW), Float(rectY / inputH),
            Float((rectX + rectW) / inputW), Float((rectY + rectH) / inputH)))

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
