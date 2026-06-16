import Foundation
import Metal

/// Imports effects and presets from `.metal`, `.shader`, `.json`, and `.spectra`
/// files. Custom shaders are compiled and validated immediately so invalid
/// imports fail safely rather than crashing the renderer.
final class ShaderImporter {
    private let compiler: ShaderCompiler

    init(compiler: ShaderCompiler) {
        self.compiler = compiler
    }

    enum Imported {
        case shader(CustomShader, MTLLibrary)
        case preset(Preset)
        case composed(ComposedEffect)
    }

    enum ImportError: LocalizedError {
        case unreadable
        case unsupported(String)
        case noFragmentFunction
        case compilation([ShaderCompiler.Diagnostic])
        case malformedDocument

        var errorDescription: String? {
            switch self {
            case .unreadable: "The file could not be read."
            case .unsupported(let ext): "Unsupported file type: .\(ext)"
            case .noFragmentFunction: "No Metal fragment function was found in the file."
            case .compilation(let diagnostics):
                "Shader failed to compile:\n" + diagnostics.prefix(6).map { d in
                    let loc = d.line.map { "line \($0): " } ?? ""
                    return "• \(loc)\(d.message)"
                }.joined(separator: "\n")
            case .malformedDocument: "The document format was not recognised."
            }
        }
    }

    func importFile(at url: URL) throws -> Imported {
        let ext = url.pathExtension.lowercased()
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }

        switch ext {
        case "spectra", "json":
            return try importDocument(data: data, fallbackName: url.deletingPathExtension().lastPathComponent)
        case "metal", "shader":
            guard let source = String(data: data, encoding: .utf8) else { throw ImportError.unreadable }
            return try importMetalSource(source, name: url.deletingPathExtension().lastPathComponent)
        default:
            throw ImportError.unsupported(ext)
        }
    }

    private func importDocument(data: Data, fallbackName: String) throws -> Imported {
        // First try a full SpectraDocument; fall back to a bare Preset or CustomShader.
        if let document = try? JSONStore.decode(SpectraDocument.self, from: data) {
            switch document.kind {
            case .preset:
                if let preset = document.preset { return .preset(preset) }
            case .shader:
                if let shader = document.shader { return try compileShader(shader) }
            case .composed:
                if let composed = document.composed { return .composed(composed) }
            }
        }
        if let preset = try? JSONStore.decode(Preset.self, from: data) {
            return .preset(preset)
        }
        if let shader = try? JSONStore.decode(CustomShader.self, from: data) {
            return try compileShader(shader)
        }
        throw ImportError.malformedDocument
    }

    private func importMetalSource(_ source: String, name: String) throws -> Imported {
        guard let function = ShaderCompiler.detectFragmentFunction(in: source) else {
            throw ImportError.noFragmentFunction
        }
        let shader = CustomShader(
            name: name, subtitle: "Imported Metal shader",
            fragmentFunction: function, source: source,
            parameters: Self.inferParameters(from: source),
            isAnimated: source.contains("u.time"))
        return try compileShader(shader)
    }

    /// Infer tunable controls for a raw `.metal` import by scanning for the
    /// highest `u.params[N]` slot referenced and generating a slider per slot, so
    /// the effect is adjustable in the inspector without any hand-written
    /// metadata. Authored `.spectra`/`.json` files carry explicit parameters and
    /// bypass this.
    static func inferParameters(from source: String) -> [EffectParameter] {
        let pattern = #"u\.params\s*\[\s*(\d+)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var maxIndex = -1
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: source),
                  let index = Int(source[r]) else { return }
            maxIndex = max(maxIndex, index)
        }
        guard maxIndex >= 0, maxIndex < 32 else { return [] }
        return (0...maxIndex).map { i in
            .slider("param\(i)", "Parameter \(i + 1)", 0...1, default: 0.5)
        }
    }

    private func compileShader(_ shader: CustomShader) throws -> Imported {
        let output = compiler.compileAndValidate(source: shader.source, fragmentFunction: shader.fragmentFunction)
        guard let library = output.library else {
            throw ImportError.compilation(output.diagnostics)
        }
        return .shader(shader, library)
    }
}
