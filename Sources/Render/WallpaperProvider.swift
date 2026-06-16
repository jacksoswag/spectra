import Foundation
@preconcurrency import Metal
import AppKit

/// Loads the desktop wallpaper for a display into a downscaled Metal texture, used
/// as the source for the Studio's live preview. Previewing against the wallpaper
/// (rather than a live screen capture) avoids the infinite-mirror recursion of
/// capturing the Studio window itself, needs no capture permission, and keeps the
/// preview cheap. Cached per display and refreshed on demand.
@MainActor
final class WallpaperProvider {
    private let device: MTLDevice
    private var cache: [CGDirectDisplayID: MTLTexture] = [:]
    private let maxWidth = 1600

    init(device: MTLDevice) {
        self.device = device
    }

    /// The wallpaper texture for a display, loading it on first request.
    func texture(for displayID: CGDirectDisplayID) -> MTLTexture? {
        if let cached = cache[displayID] { return cached }
        let texture = load(displayID) ?? makeFallback()
        cache[displayID] = texture
        return texture
    }

    /// Drop cached wallpapers so the next request reloads (display or wallpaper change).
    func refresh() { cache.removeAll() }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func load(_ displayID: CGDirectDisplayID) -> MTLTexture? {
        guard let screen = screen(for: displayID),
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return texture(from: cgImage)
    }

    /// Render a CGImage into a downscaled RGBA8 texture.
    private func texture(from cgImage: CGImage, fallbackBytes: [UInt8]? = nil) -> MTLTexture? {
        let srcW = cgImage.width, srcH = cgImage.height
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1.0, Double(maxWidth) / Double(srcW))
        let w = max(1, Int(Double(srcW) * scale))
        let h = max(1, Int(Double(srcH) * scale))

        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: bytesPerRow)
        return texture
    }

    /// A neutral gradient used when the wallpaper can't be read (e.g. a dynamic
    /// desktop), so the preview always shows something.
    private func makeFallback() -> MTLTexture? {
        let w = 640, h = 400
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                bytes[i + 0] = UInt8(40 + (x * 120) / w)
                bytes[i + 1] = UInt8(50 + (y * 120) / h)
                bytes[i + 2] = UInt8(90 + ((x + y) * 80) / (w + h))
                bytes[i + 3] = 255
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        return texture
    }
}
