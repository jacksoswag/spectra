import AppKit
import Metal
import QuartzCore

/// Owns every main-thread-only AppKit read needed to draw the live cursor — the mouse
/// position (`NSEvent.mouseLocation`), the system cursor sprite (`NSCursor`/`NSImage`), its
/// size and hot-spot — and publishes them as an immutable, thread-safe snapshot the off-main
/// render callback consumes.
///
/// The render callback now runs on a dedicated link thread (see `RenderLinkThread`), where
/// `NSEvent`/`NSCursor`/`NSImage` are illegal to touch. So all of that lives here on the main
/// actor; only a finished `MTLTexture` plus scalars cross the thread boundary, read lock-free
/// of AppKit via `current()`.
///
/// Sampling runs on a ~60Hz main timer that exists only while the custom cursor is engaged, so
/// the feature costs nothing when off.
@MainActor
final class CursorSampler {
    /// An immutable view of the cursor for one render frame. `texture` is freshly allocated
    /// whenever the sprite changes (never mutated in place), so a render frame that captured an
    /// older snapshot keeps sampling a stable, still-valid texture.
    struct Snapshot {
        var texture: MTLTexture?
        var sizePoints: CGSize = .zero
        var hotSpot: CGPoint = .zero
        /// AppKit global coordinates (bottom-left origin), matching `OverlayWindow.frame` so
        /// the compositor's placement math is unchanged.
        var position: CGPoint = .zero
    }

    private let device: MTLDevice
    private let lock = NSLock()
    /// Guarded by `lock` so the nonisolated `current()` (render thread) and the main-actor
    /// `publish`/`sample` can both touch it safely.
    nonisolated(unsafe) private var snapshot = Snapshot()

    private var timer: Timer?
    private var lastImage: NSImage?
    private var cachedSprite: Sprite?
    /// Cap the rasterized sprite so an unusual cursor can't blow up the texture.
    private let maxDimension = 192

    private(set) var enabled = false

    init(device: MTLDevice) { self.device = device }

    /// Thread-safe: read the latest published snapshot. Called from the render (link) thread.
    nonisolated func current() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Engage/disengage live cursor sampling. Engaging publishes one snapshot immediately so
    /// the first rendered frame already has a sprite; disengaging stops the timer and clears the
    /// snapshot so the compositor stops drawing the cursor.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            sample()
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            lastImage = nil
            cachedSprite = nil
            publish(Snapshot())
        }
    }

    private func publish(_ s: Snapshot) {
        lock.lock(); snapshot = s; lock.unlock()
    }

    /// Refresh the sprite if the system cursor changed, then publish it with the current mouse
    /// position.
    private func sample() {
        var next = Snapshot()
        next.position = NSEvent.mouseLocation
        if let sprite = refreshSprite() {
            next.texture = sprite.texture
            next.sizePoints = sprite.sizePoints
            next.hotSpot = sprite.hotSpot
        }
        publish(next)
    }

    private struct Sprite {
        var texture: MTLTexture
        var sizePoints: CGSize
        var hotSpot: CGPoint
    }

    /// Rebuild the cursor sprite when the system cursor's image changes, into a FRESH immutable
    /// texture each time. Never reuses or `.replace`s a texture the render thread may still be
    /// sampling — the old texture stays retained by any in-flight frame's captured snapshot
    /// until its GPU work completes.
    private func refreshSprite() -> Sprite? {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        if image === lastImage, let cachedSprite { return cachedSprite }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return cachedSprite   // keep the previous sprite if extraction fails
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
        guard drew else { return cachedSprite }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: pxW, height: pxH, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return cachedSprite }
        bytes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: pxW, height: pxH, depth: 1)),
                mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        let sprite = Sprite(texture: texture, sizePoints: image.size, hotSpot: cursor.hotSpot)
        cachedSprite = sprite
        lastImage = image
        return sprite
    }
}
