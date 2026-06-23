import Foundation
import Metal

/// Recycles transient render-target textures to avoid per-frame allocation and
/// unnecessary copies. Textures are acquired during chain encoding and returned
/// once the GPU finishes (from the command buffer completion handler), so an
/// in-flight frame never aliases another's working set.
///
/// Every mutable field is guarded by `lock`, so the pool is safe to reference
/// from GPU completion handlers that run on arbitrary threads.
final class TexturePool: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var free: [Key: [MTLTexture]] = [:]
    private var pooledBytes = 0
    /// A 1×1 texture allocated up front while the device is known-good (TexturePool is built
    /// right after `MetalContext` proves the device). Handed back if a later allocation fails
    /// on a faulted device, so the hot path never force-unwraps a `nil` and crashes mid-frame.
    private let sentinel: MTLTexture

    /// Hard cap on retained pool memory. The renderer recycles intermediates
    /// within a frame, so the real working set is only a few textures per
    /// in-flight frame; this ceiling exists to evict buckets stranded by a
    /// resolution change (adaptive quality), not to bound the live set. Kept
    /// generous so it never evicts textures that are about to be reused (which
    /// would force per-frame reallocation of large textures).
    private let maxPooledBytes = 1536 * 1024 * 1024
    /// Soft cap on textures retained per (size, format, usage) bucket.
    private let maxPerBucket = 16

    private struct Key: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: UInt
        let usage: UInt

        /// Bytes per texture in this bucket.
        var byteSize: Int {
            let bpp = MTLPixelFormat(rawValue: pixelFormat)?.spectraBytesPerPixel ?? 8
            return width * height * bpp
        }
    }

    init(device: MTLDevice) {
        self.device = device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.workingPixelFormat, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget, .shaderWrite]
        descriptor.storageMode = .private
        guard let sentinel = device.makeTexture(descriptor: descriptor) else {
            // The device just initialised successfully in MetalContext; a device that cannot
            // allocate a 1×1 texture is unusable and the app cannot render regardless.
            preconditionFailure("TexturePool: Metal device cannot allocate a 1×1 texture")
        }
        self.sentinel = sentinel
    }

    /// Approximate VRAM footprint of pooled textures, in bytes.
    var pooledByteEstimate: Int {
        lock.lock(); defer { lock.unlock() }
        return pooledBytes
    }

    func acquire(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = MetalContext.workingPixelFormat,
        usage: MTLTextureUsage = [.shaderRead, .renderTarget, .shaderWrite]
    ) -> MTLTexture {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let key = Key(width: safeWidth, height: safeHeight,
                      pixelFormat: pixelFormat.rawValue, usage: usage.rawValue)

        lock.lock()
        if var bucket = free[key], let texture = bucket.popLast() {
            free[key] = bucket
            pooledBytes -= key.byteSize
            lock.unlock()
            return texture
        }
        lock.unlock()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: safeWidth, height: safeHeight, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            // Allocation failed (transient VRAM pressure on a large target). Retry at 1×1 in the
            // SAME format/usage so the binding stays valid; if even that fails the device is
            // faulted and we hand back the init-time sentinel rather than crashing mid-frame.
            let fallback = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: 1, height: 1, mipmapped: false)
            fallback.usage = usage
            fallback.storageMode = .private
            return device.makeTexture(descriptor: fallback) ?? sentinel
        }
        texture.label = "SpectraPool \(safeWidth)x\(safeHeight)"
        return texture
    }

    func release(_ texture: MTLTexture) {
        // Never pool the shared 1×1 fallback sentinel: it can be handed out by the OOM path, and
        // pooling it could later vend the same object to two passes at once (a resource hazard).
        if texture === sentinel { return }
        let key = Key(width: texture.width, height: texture.height,
                      pixelFormat: texture.pixelFormat.rawValue, usage: texture.usage.rawValue)
        lock.lock()
        defer { lock.unlock() }
        // Drop rather than cache if this bucket is full or the pool is at its cap;
        // evict stale (other-size) buckets first to make room.
        if (free[key]?.count ?? 0) >= maxPerBucket { return }
        if pooledBytes + key.byteSize > maxPooledBytes {
            evictDownTo(maxPooledBytes - key.byteSize, keeping: key)
            if pooledBytes + key.byteSize > maxPooledBytes { return }
        }
        free[key, default: []].append(texture)
        pooledBytes += key.byteSize
    }

    func release(_ textures: [MTLTexture]) {
        for texture in textures { release(texture) }
    }

    /// Evict cached textures until under `target` bytes, preferring buckets other
    /// than `keeping` (stale resolutions left behind by adaptive quality). Must be
    /// called with the lock held.
    private func evictDownTo(_ target: Int, keeping: Key) {
        for (key, var bucket) in free where key != keeping {
            while pooledBytes > target, !bucket.isEmpty {
                bucket.removeLast()
                pooledBytes -= key.byteSize
            }
            free[key] = bucket.isEmpty ? nil : bucket
            if pooledBytes <= target { return }
        }
    }

    /// Drop all cached textures (e.g. on a resolution change) to free VRAM.
    func purge() {
        lock.lock()
        free.removeAll()
        pooledBytes = 0
        lock.unlock()
    }
}

extension MTLPixelFormat {
    /// Bytes per pixel for the formats Spectra uses as render targets.
    var spectraBytesPerPixel: Int {
        switch self {
        case .rgba16Float: 8
        case .rgba32Float: 16
        case .bgra8Unorm, .rgba8Unorm, .bgra8Unorm_srgb, .rgb10a2Unorm: 4
        case .r16Float: 2
        case .r8Unorm: 1
        default: 8
        }
    }
}
