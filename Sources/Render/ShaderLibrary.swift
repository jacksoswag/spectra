import Foundation
import Metal

/// Builds and caches render pipeline states. Every effect pass uses the shared
/// `fullscreen_vertex` and an effect-specific fragment function, so pipelines are
/// keyed by (fragment function, output pixel format, library identity).
final class ShaderLibrary {
    private let context: MetalContext
    private let lock = NSLock()
    private var cache: [Key: MTLRenderPipelineState] = [:]
    private var computeCache: [FunctionKey: MTLComputePipelineState] = [:]
    private var functionCache: [FunctionKey: MTLFunction] = [:]

    private struct Key: Hashable {
        let function: String
        let pixelFormat: UInt
        let libraryID: ObjectIdentifier?
    }

    private struct FunctionKey: Hashable {
        let function: String
        let libraryID: ObjectIdentifier?
    }

    enum ShaderError: LocalizedError {
        case missingFunction(String)

        var errorDescription: String? {
            switch self {
            case .missingFunction(let name): "Shader function '\(name)' was not found."
            }
        }
    }

    init(context: MetalContext) {
        self.context = context
    }

    /// Return (creating if needed) a pipeline for the given fragment function.
    /// Pass a custom `library` for runtime-compiled shaders; otherwise the app's
    /// default library is used.
    func pipeline(
        fragment functionName: String,
        pixelFormat: MTLPixelFormat,
        library: MTLLibrary? = nil
    ) throws -> MTLRenderPipelineState {
        let lib = library ?? context.defaultLibrary
        let key = Key(function: functionName, pixelFormat: pixelFormat.rawValue,
                      libraryID: library.map(ObjectIdentifier.init))

        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[key] { return cached }

        let vertex = try makeFunction("fullscreen_vertex", in: context.defaultLibrary)
        let fragment = try makeFunction(functionName, in: lib)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Spectra.\(functionName)"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.rasterSampleCount = 1

        let state = try context.device.makeRenderPipelineState(descriptor: descriptor)
        cache[key] = state
        return state
    }

    /// Return (creating if needed) a compute pipeline for a kernel function. Used by
    /// passes flagged `isCompute` (e.g. the tile-cached painterly).
    func computePipeline(
        _ functionName: String,
        library: MTLLibrary? = nil
    ) throws -> MTLComputePipelineState {
        let lib = library ?? context.defaultLibrary
        let key = FunctionKey(function: functionName, libraryID: library.map(ObjectIdentifier.init))

        lock.lock()
        defer { lock.unlock() }

        if let cached = computeCache[key] { return cached }
        let function = try makeFunction(functionName, in: lib)
        let state = try context.device.makeComputePipelineState(function: function)
        computeCache[key] = state
        return state
    }

    /// Warm a set of fragment functions for a pixel format ahead of time to
    /// avoid first-use hitching.
    func prewarm(functions: [String], pixelFormat: MTLPixelFormat) {
        for name in functions {
            _ = try? pipeline(fragment: name, pixelFormat: pixelFormat)
        }
    }

    /// Validate that a fragment function exists (used by the importer/editor).
    func functionExists(_ name: String, in library: MTLLibrary? = nil) -> Bool {
        let lib = library ?? context.defaultLibrary
        return lib.functionNames.contains(name)
    }

    private func makeFunction(_ name: String, in library: MTLLibrary) throws -> MTLFunction {
        let key = FunctionKey(function: name, libraryID: ObjectIdentifier(library))
        if let cached = functionCache[key] { return cached }
        guard let function = library.makeFunction(name: name) else {
            throw ShaderError.missingFunction(name)
        }
        functionCache[key] = function
        return function
    }
}
