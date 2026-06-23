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

    /// The active cursor styling (MAOE §6). Set from the main actor via `setSpec`. A `sprite`
    /// style is the world's own pointer: its art is shown whenever the style is active, decoupled
    /// from any system-cursor detection. Restyle variants leave sprite selection to the system and
    /// are applied later in the compositor shader.
    private var spec: CursorSpec = .systemDefault
    /// Lazily-loaded bundle sprites + the asset names whose art was missing (so we don't retry
    /// every frame — a missing variant degrades to the world's arrow). Keyed by full asset basename
    /// (e.g. "noir-object", "noir-object-text") so the per-role variants cache independently.
    private var spriteCache: [String: Sprite] = [:]
    private var spriteLoadFailed: Set<String> = []
    /// Authored hotspots (points) per asset basename, from `cursor-hotspots.json`.
    private var hotspots: [String: CGPoint] = [:]

    private(set) var enabled = false

    init(device: MTLDevice) {
        self.device = device
        loadHotspots()
    }

    /// The shape the live system cursor currently is, used to pick a sprite variant.
    private enum CursorRole {
        case arrow, text, hand
        var suffix: String { switch self { case .arrow: ""; case .text: "-text"; case .hand: "-hand" } }
    }

    /// Classify `NSCursor.currentSystem` by its NORMALISED hotspot position (no cursor-type API
    /// exists, and `NSCursor.iBeam.image.size` reports (0,0), so absolute matching can't work):
    ///   • centred hotspot  → text caret (I-beam)
    ///   • upper-centre hotspot → link hand (fingertip)
    ///   • otherwise (hotspot at a corner) → arrow
    /// Cheap (reads the NSImage size + hotspot, no rasterization), so it can run per frame.
    private func currentCursorRole() -> CursorRole {
        guard let cur = NSCursor.currentSystem else { return .arrow }
        let sz = cur.image.size
        guard sz.width > 1, sz.height > 1 else { return .arrow }
        let rx = cur.hotSpot.x / sz.width, ry = cur.hotSpot.y / sz.height
        if rx > 0.38 && rx < 0.62 && ry > 0.38 && ry < 0.62 { return .text }   // centred = caret
        if rx > 0.30 && rx < 0.58 && ry < 0.42 { return .hand }                // upper-centre = fingertip
        return .arrow
    }

    /// Set the active cursor styling. Invalidates the cached sprite so the change takes effect
    /// on the next sample, and re-publishes immediately when already engaged.
    func setSpec(_ s: CursorSpec) {
        guard s != spec else { return }
        spec = s
        cachedSprite = nil
        lastImage = nil
        if enabled { sample() }
    }

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
        // User-supplied Custom Cursor (MAOE §6): load the image for the live role (arrow / hand /
        // text), falling back to the arrow image when a role's slot is empty. A missing file
        // degrades to the live system cursor below.
        if let images = spec.style.customImages {
            let role = currentCursorRole()
            let pick = (role == .hand ? images.hand : role == .text ? images.text : images.arrow)
            let name = pick.isEmpty ? images.arrow : pick
            if !name.isEmpty, let s = customSprite(name) { return s }
        }
        // Bespoke sprite worlds (MAOE §6): the world's pointer IS the sprite, so it renders
        // whenever the style is active — its appearance is independent of what shape the system
        // cursor currently is. The bundle sprite is cached, so this is a cheap dictionary hit per
        // frame. A missing asset degrades to the live system cursor below.
        if let kind = spec.style.spriteKind {
            // Swap among arrow / I-beam / hand variants by the live system cursor role; a missing
            // variant falls back to the world's arrow sprite.
            let role = currentCursorRole()
            if let s = bundleSprite(kind.assetName + role.suffix) ?? bundleSprite(kind.assetName) { return s }
        }

        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        if image === lastImage, let cachedSprite { return cachedSprite }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return cachedSprite   // keep the previous sprite if extraction fails
        }
        let scale: CGFloat = 2   // rasterize @2x for crisp Retina edges
        let pxW = min(maxDimension, max(1, Int((image.size.width * scale).rounded())))
        let pxH = min(maxDimension, max(1, Int((image.size.height * scale).rounded())))
        guard let texture = makeTexture(from: cgImage, pxW: pxW, pxH: pxH) else { return cachedSprite }
        let sprite = Sprite(texture: texture, sizePoints: image.size, hotSpot: cursor.hotSpot)
        cachedSprite = sprite
        lastImage = image
        return sprite
    }

    /// Rasterize a CGImage into a fresh premultiplied rgba8 MTLTexture (top-row-first to match
    /// the shader's top-left UV origin).
    private func makeTexture(from cgImage: CGImage, pxW: Int, pxH: Int) -> MTLTexture? {
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
        guard drew else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: pxW, height: pxH, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size: MTLSize(width: pxW, height: pxH, depth: 1)),
                mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return texture
    }

    /// Load a bespoke sprite from the bundle (`<assetName>@2x.png`), building a @2x texture with
    /// the authored hotspot. Cached; a missing asset is recorded so it isn't retried each frame.
    private func bundleSprite(_ asset: String) -> Sprite? {
        if let cached = spriteCache[asset] { return cached }
        if spriteLoadFailed.contains(asset) { return nil }
        guard let url = Bundle.main.url(forResource: asset + "@2x", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            spriteLoadFailed.insert(asset)   // expected for absent variants — caller falls back to the arrow
            return nil
        }
        let pxW = min(maxDimension, cg.width), pxH = min(maxDimension, cg.height)
        guard let texture = makeTexture(from: cg, pxW: pxW, pxH: pxH) else {
            spriteLoadFailed.insert(asset); return nil
        }
        let scale: CGFloat = 2   // art is authored @2x
        let hot = hotspots[asset] ?? CGPoint(x: 1, y: 1)
        let sprite = Sprite(texture: texture,
                            sizePoints: CGSize(width: CGFloat(pxW) / scale, height: CGFloat(pxH) / scale),
                            hotSpot: hot)
        spriteCache[asset] = sprite
        return sprite
    }

    /// Load a user-supplied cursor image from `AppPaths.cursorsDirectory/<filename>`, cached by
    /// filename. User art carries no authored hotspot, so the active point defaults to the top-left
    /// tip; the picked file is treated as @2x for a sensible on-screen size.
    private func customSprite(_ filename: String) -> Sprite? {
        if let cached = spriteCache[filename] { return cached }
        if spriteLoadFailed.contains(filename) { return nil }
        // Sanitize: the filename comes from a preset/param and must not escape the cursors dir.
        let url = AppPaths.cursorsDirectory.appendingPathComponent(AppPaths.safeComponent(filename))
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            spriteLoadFailed.insert(filename)
            return nil
        }
        let pxW = min(maxDimension, cg.width), pxH = min(maxDimension, cg.height)
        guard let texture = makeTexture(from: cg, pxW: pxW, pxH: pxH) else {
            spriteLoadFailed.insert(filename); return nil
        }
        let scale: CGFloat = 2
        let sprite = Sprite(texture: texture,
                            sizePoints: CGSize(width: CGFloat(pxW) / scale, height: CGFloat(pxH) / scale),
                            hotSpot: CGPoint(x: 0, y: 0))
        spriteCache[filename] = sprite
        return sprite
    }

    /// Load authored hotspots (points) for every sprite from `cursor-hotspots.json`.
    private func loadHotspots() {
        guard let url = Bundle.main.url(forResource: "cursor-hotspots", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else { return }
        for (name, p) in raw {
            if let x = p["x"], let y = p["y"] { hotspots[name] = CGPoint(x: x, y: y) }
        }
    }
}
