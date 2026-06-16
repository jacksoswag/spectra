import Foundation
import Metal
import Observation

/// Owns user-authored / imported custom shaders: compilation, registration with
/// the `EffectRegistry`, and persistence. Bridges the editor, the importer, and
/// the effect library.
@MainActor
@Observable
final class CustomShaderStore {
    private(set) var shaders: [CustomShader] = []

    private let context: MetalContext
    private let compiler: ShaderCompiler
    private let registry: EffectRegistry

    init(context: MetalContext, compiler: ShaderCompiler, registry: EffectRegistry) {
        self.context = context
        self.compiler = compiler
        self.registry = registry
        load()
    }

    func library(for id: String) -> MTLLibrary? { registry.customLibrary(for: id) }

    /// Compile, register, and persist a shader. Returns the compilation output so
    /// the editor can surface diagnostics; throws only on a hard error.
    @discardableResult
    func upsert(_ shader: CustomShader) -> ShaderCompiler.CompilationOutput {
        let output = compiler.compileAndValidate(source: shader.source, fragmentFunction: shader.fragmentFunction)
        guard output.succeeded, let library = output.library else { return output }

        registry.registerCustom(shader.makeDescriptor(), library: library)
        if let index = shaders.firstIndex(where: { $0.id == shader.id }) {
            shaders[index] = shader
        } else {
            shaders.append(shader)
        }
        persist(shader)
        return output
    }

    func remove(_ id: String) {
        shaders.removeAll { $0.id == id }
        registry.unregister(id)
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    func export(_ shader: CustomShader, to url: URL) throws {
        try JSONStore.save(SpectraDocument.shader(shader), to: url)
    }

    // MARK: - Persistence

    private func fileURL(for id: String) -> URL {
        AppPaths.shadersDirectory.appendingPathComponent("\(id).json")
    }

    private func persist(_ shader: CustomShader) {
        try? JSONStore.save(SpectraDocument.shader(shader), to: fileURL(for: shader.id))
    }

    private func load() {
        AppPaths.ensureDirectories()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.shadersDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let document = JSONStore.load(SpectraDocument.self, from: file),
                  let shader = document.shader else { continue }
            let output = compiler.compileAndValidate(source: shader.source, fragmentFunction: shader.fragmentFunction)
            if output.succeeded, let library = output.library {
                registry.registerCustom(shader.makeDescriptor(), library: library)
                shaders.append(shader)
            } else {
                Log.editor.error("Custom shader '\(shader.name)' failed to load: skipped.")
            }
        }
    }
}
