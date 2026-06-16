import AppKit
import Metal
import QuartzCore

/// Rasterizes the live system cursor to a texture and composites it onto a
/// captured frame at the live mouse position, so the cursor can be sent through
/// the effect chain (rather than mirrored late through the capture, which lags).
///
/// All methods run on the main thread — the display-link callback that drives
/// `DisplayRenderer.renderFrame` fires on the main run loop, where `NSEvent` and
/// `NSCursor` are valid to read.
final class CursorCompositor {
    /// Toggled by the coordinator from the "Custom cursor" setting.
    var enabled = false

    private let device: MTLDevice
    private let shaders: ShaderLibrary

    private var cursorTexture: MTLTexture?
    private var lastImage: NSImage?
    private var sizePoints: CGSize = .zero
    private var hotSpot: CGPoint = .zero
    /// Cap the rasterized sprite so an unusual cursor can't blow up the texture.
    private let maxDimension = 192

    private struct CursorUniforms { var rect: SIMD4<Float> }

    init(device: MTLDevice, shaders: ShaderLibrary) {
        self.device = device
        self.shaders = shaders
    }

    /// If enabled and the pointer is over `displayFramePoints`, return a new pool
    /// texture holding `input` with the cursor drawn on top; otherwise nil (use
    /// `input` unchanged). The returned texture must be released by the caller once
    /// the GPU completes the command buffer.
    func composite(input: MTLTexture, displayFramePoints frame: CGRect,
                   into commandBuffer: MTLCommandBuffer, pool: TexturePool) -> MTLTexture? {
        guard enabled, frame.width > 0, frame.height > 0 else { return nil }
        let mouse = NSEvent.mouseLocation
        guard frame.contains(mouse) else { return nil }      // cursor is on another display
        guard refreshCursor(), let cursorTexture else { return nil }

        let inputW = CGFloat(input.width)
        let inputH = CGFloat(input.height)
        // Input pixels per display point (folds in backing scale and any adaptive
        // downscale uniformly).
        let sx = inputW / frame.width
        let sy = inputH / frame.height
        // Mouse position within the display, converted to a top-left pixel origin.
        let relX = mouse.x - frame.minX
        let topY = frame.height - (mouse.y - frame.minY)
        let rectX = (relX - hotSpot.x) * sx
        let rectY = (topY - hotSpot.y) * sy
        let rectW = sizePoints.width * sx
        let rectH = sizePoints.height * sy

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

    /// Rebuild `cursorTexture` from the current system cursor when its image
    /// changes. Returns false only if no usable cursor texture is available.
    private func refreshCursor() -> Bool {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        if image === lastImage, cursorTexture != nil { return true }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return cursorTexture != nil   // keep the previous sprite if extraction fails
        }
        let scale: CGFloat = 2   // rasterize @2x for crisp Retina edges
        let pxW = min(maxDimension, max(1, Int((image.size.width * scale).rounded())))
        let pxH = min(maxDimension, max(1, Int((image.size.height * scale).rounded())))
        let bytesPerRow = pxW * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pxH)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: pxW, height: pxH, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
            return true
        }
        guard drew else { return cursorTexture != nil }

        if cursorTexture?.width != pxW || cursorTexture?.height != pxH {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: pxW, height: pxH, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            cursorTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let cursorTexture else { return false }
        bytes.withUnsafeBytes { raw in
            cursorTexture.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: pxW, height: pxH, depth: 1)),
                mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        sizePoints = image.size
        hotSpot = cursor.hotSpot
        lastImage = image
        return true
    }
}
