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
        usage: MTLTextureUsage = [.shaderRead, .renderTarget]
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
            // Extremely unlikely; fall back to a tiny texture to avoid a crash.
            let fallback = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: 1, height: 1, mipmapped: false)
            fallback.usage = usage
            return device.makeTexture(descriptor: fallback)!
        }
        texture.label = "SpectraPool \(safeWidth)x\(safeHeight)"
        return texture
    }

    func release(_ texture: MTLTexture) {
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
