import Foundation
@preconcurrency import Metal
import AppKit

/// Renders an effect chain over a synthetic sample image to a small PNG, used to
/// generate library thumbnails / preview images for composed effects. Runs
/// synchronously on demand; returns nil on any failure (callers fall back to the
/// category icon).
@MainActor
final class ThumbnailRenderer {
    private let context: MetalContext
    private let shaders: ShaderLibrary
    private let pool: TexturePool
    private let chainRenderer: EffectChainRenderer
    private let width = 240
    private let height = 150

    init(context: MetalContext, shaders: ShaderLibrary) {
        self.context = context
        self.shaders = shaders
        self.pool = TexturePool(device: context.device)
        self.chainRenderer = EffectChainRenderer(context: context, shaders: shaders, pool: pool)
    }

    /// Render the chain and return a base64-encoded PNG, or nil on failure.
    func renderBase64PNG(chain: [ResolvedEffect]) -> String? {
        guard let input = makeSampleTexture(),
              let readback = makeReadbackTexture(),
              let commandBuffer = context.commandQueue.makeCommandBuffer() else { return nil }

        let frame = FrameContext(time: 1.2, frameIndex: 72)   // mid-animation, stable
        let result = chainRenderer.encode(into: commandBuffer, input: input, chain: chain, frame: frame)

        guard let pipeline = try? shaders.pipeline(
            fragment: "passthrough_fragment", pixelFormat: readback.pixelFormat) else { return nil }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = readback
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(result.outputTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: readback)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        pool.release(result.transientTextures)

        return encodePNG(from: readback)
    }

    // MARK: - Sample image

    private func makeSampleTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(width - 1)
                let v = Double(y) / Double(height - 1)
                // Colourful gradient with a soft highlight and dark corner so
                // colour, contrast, blur, and bloom effects all read clearly.
                let r = 0.15 + 0.8 * u
                let g = 0.2 + 0.7 * (1.0 - v)
                let b = 0.3 + 0.6 * (0.5 + 0.5 * cos((u + v) * 6.28318))
                let d = hypot(u - 0.32, v - 0.4)
                let highlight = max(0, 1.0 - d * 2.4)
                let i = (y * width + x) * 4
                bytes[i + 0] = UInt8(min(1.0, r + highlight) * 255)
                bytes[i + 1] = UInt8(min(1.0, g + highlight) * 255)
                bytes[i + 2] = UInt8(min(1.0, b + highlight * 0.8) * 255)
                bytes[i + 3] = 255
            }
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    private func makeReadbackTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        return context.device.makeTexture(descriptor: descriptor)
    }

    private func encodePNG(from texture: MTLTexture) -> String? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &bytes, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
            let dest = rep.bitmapData else { return nil }
        dest.update(from: bytes, count: bytes.count)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }
}

extension ComposedEffect {
    /// Decode the stored thumbnail PNG, if any.
    var thumbnailImage: NSImage? {
        guard let base64 = thumbnailPNGBase64,
              let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else { return nil }
        return image
    }
}
