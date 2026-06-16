import Foundation
import Metal

/// Compiles custom Metal source at runtime, prepending the Spectra prelude so
/// authored shaders can use the full helper library. Parses compiler output into
/// structured diagnostics for the editor. Compilation failures are surfaced as
/// errors (never crashes), which sandboxes malformed imports.
final class ShaderCompiler {
    private let context: MetalContext
    private let preludeLineCount: Int

    init(context: MetalContext) {
        self.context = context
        self.preludeLineCount = ShaderPrelude.source.components(separatedBy: "\n").count
    }

    struct Diagnostic: Identifiable, Hashable {
        enum Severity: String { case error, warning, note }
        let id = UUID()
        let line: Int?
        let column: Int?
        let severity: Severity
        let message: String
    }

    struct CompilationOutput {
        let library: MTLLibrary?
        let diagnostics: [Diagnostic]
        var succeeded: Bool { library != nil && !diagnostics.contains { $0.severity == .error } }
    }

    /// Remove declarations the prelude already provides so imported full-file
    /// shaders don't double-declare.
    static func sanitize(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#include <metal_stdlib>") { return false }
                if trimmed.hasPrefix("#include \"SpectraCommon.h\"") { return false }
                if trimmed.hasPrefix("using namespace metal;") { return false }
                return true
            }
            .joined(separator: "\n")
    }

    /// Compile and return the library plus diagnostics. Does not throw.
    func compile(source: String) -> CompilationOutput {
        let full = ShaderPrelude.source + "\n" + Self.sanitize(source)
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0   // pin the language version for imports
        do {
            let library = try context.device.makeLibrary(source: full, options: options)
            return CompilationOutput(library: library, diagnostics: [])
        } catch {
            let diagnostics = parse(error.localizedDescription)
            return CompilationOutput(
                library: nil,
                diagnostics: diagnostics.isEmpty
                    ? [Diagnostic(line: nil, column: nil, severity: .error, message: error.localizedDescription)]
                    : diagnostics)
        }
    }

    /// Compile and require that a fragment function exists.
    func compileAndValidate(source: String, fragmentFunction: String) -> CompilationOutput {
        let output = compile(source: source)
        guard let library = output.library else { return output }
        var diagnostics = output.diagnostics
        if !library.functionNames.contains(fragmentFunction) {
            diagnostics.append(Diagnostic(
                line: nil, column: nil, severity: .error,
                message: "Fragment function '\(fragmentFunction)' not found. Available: \(library.functionNames.joined(separator: ", "))"))
            return CompilationOutput(library: nil, diagnostics: diagnostics)
        }
        diagnostics.append(contentsOf: Self.safetyWarnings(source))
        return CompilationOutput(library: library, diagnostics: diagnostics)
    }

    /// Lightweight static checks that flag patterns likely to hang the GPU in an
    /// imported shader (an unbounded loop). A warning, not a hard block — the
    /// renderer additionally disables any effect that faults at runtime.
    static func safetyWarnings(_ source: String) -> [Diagnostic] {
        let patterns = [#"while\s*\(\s*true\s*\)"#, #"while\s*\(\s*1\s*\)"#, #"for\s*\(\s*;\s*;\s*\)"#]
        let hasUnbounded = patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                in: source, range: NSRange(source.startIndex..., in: source)) != nil
        }
        guard hasUnbounded else { return [] }
        return [Diagnostic(
            line: nil, column: nil, severity: .warning,
            message: "Possible unbounded loop detected. Ensure it has a guaranteed exit, or the GPU may hang.")]
    }

    /// Detect the first fragment function name in source (for `.metal` imports).
    static func detectFragmentFunction(in source: String) -> String? {
        let pattern = #"fragment\s+\w[\w<>\s,]*?\s+(\w+)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let r = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[r])
    }

    // MARK: - Diagnostic parsing

    private func parse(_ raw: String) -> [Diagnostic] {
        // Metal emits lines like: program_source:LINE:COL: error: message
        let pattern = #"program_source:(\d+):(\d+):\s*(error|warning|note):\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var diagnostics: [Diagnostic] = []
        for line in raw.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }
            func group(_ i: Int) -> String { Range(match.range(at: i), in: line).map { String(line[$0]) } ?? "" }
            let reportedLine = Int(group(1)) ?? 0
            let userLine = max(1, reportedLine - preludeLineCount)
            let severity = Diagnostic.Severity(rawValue: group(3)) ?? .error
            diagnostics.append(Diagnostic(
                line: userLine, column: Int(group(2)), severity: severity, message: group(4)))
        }
        return diagnostics
    }
}
