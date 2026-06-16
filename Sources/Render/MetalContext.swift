import Foundation
import Metal
import CoreVideo

/// Central GPU resources, created once and dependency-injected throughout the
/// render and capture subsystems. Deliberately not a singleton — the owning
/// `AppEnvironment` holds the single instance and passes it down.
final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    /// The app's compiled shader library (built from the `.metal` sources).
    let defaultLibrary: MTLLibrary
    /// Zero-copy bridge from `CVPixelBuffer`/`IOSurface` to `MTLTexture`.
    let textureCache: CVMetalTextureCache

    /// Working pixel format for the effect chain. 16-bit float gives headroom
    /// for multi-pass grading without banding.
    static let workingPixelFormat: MTLPixelFormat = .rgba16Float

    enum ContextError: LocalizedError {
        case noDevice
        case noQueue
        case noLibrary
        case textureCacheFailed(CVReturn)

        var errorDescription: String? {
            switch self {
            case .noDevice: "No Metal-capable GPU is available."
            case .noQueue: "Could not create a Metal command queue."
            case .noLibrary: "Could not load the Spectra shader library."
            case .textureCacheFailed(let code): "Failed to create the Metal texture cache (\(code))."
            }
        }
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ContextError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw ContextError.noQueue }
        self.device = device
        self.commandQueue = queue
        queue.label = "com.spectra.render"

        do {
            self.defaultLibrary = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            Log.shader.error("Failed to load default Metal library: \(error.localizedDescription)")
            throw ContextError.noLibrary
        }

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw ContextError.textureCacheFailed(status)
        }
        self.textureCache = cache
    }
}
