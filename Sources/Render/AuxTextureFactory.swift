import Foundation
@preconcurrency import Metal
import simd

/// Bakes texture-backed parameter values (tone curves, gradients, color LUTs)
/// into `MTLTexture`s that the renderer binds alongside an effect's uniforms.
/// Built at resolve time (when a chain or parameter changes), not per frame.
@MainActor
final class AuxTextureFactory {
    private let device: MTLDevice
    private let curveResolution = 256
    private let gradientResolution = 256
    private let lutSize = 33

    init(device: MTLDevice) {
        self.device = device
    }

    /// All built-in LUT identifiers, in menu order.
    static var builtInLUTs: [String] { LUTLooks.names }

    // MARK: - Curve (1D, R)

    /// A 256×1 R16Float texture mapping input (x) to output (y) of the tone curve.
    func curveTexture(_ points: [CurvePoint]) -> MTLTexture? {
        let sorted = points.sorted { $0.x < $1.x }
        guard sorted.count >= 2 else { return nil }
        var samples = [Float](repeating: 0, count: curveResolution)
        for i in 0..<curveResolution {
            let x = Double(i) / Double(curveResolution - 1)
            samples[i] = Float(evaluate(sorted, at: x))
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: curveResolution, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let halfs = samples.map { float16From($0) }
        halfs.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, curveResolution, 1),
                            mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: curveResolution * 2)
        }
        return texture
    }

    /// Monotonic linear interpolation between clamped curve points.
    private func evaluate(_ sorted: [CurvePoint], at x: Double) -> Double {
        if x <= sorted.first!.x { return clamp01(sorted.first!.y) }
        if x >= sorted.last!.x { return clamp01(sorted.last!.y) }
        for i in 1..<sorted.count {
            if x <= sorted[i].x {
                let a = sorted[i - 1], b = sorted[i]
                let t = (x - a.x) / max(b.x - a.x, 1e-6)
                return clamp01(a.y + (b.y - a.y) * t)
            }
        }
        return clamp01(sorted.last!.y)
    }

    // MARK: - Gradient (1D, RGBA)

    func gradientTexture(_ stops: [GradientStop]) -> MTLTexture? {
        let sorted = stops.sorted { $0.position < $1.position }
        guard sorted.count >= 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: gradientResolution * 4)
        for i in 0..<gradientResolution {
            let p = Double(i) / Double(gradientResolution - 1)
            let c = sampleGradient(sorted, at: p)
            let o = i * 4
            bytes[o + 0] = toByte(c.x); bytes[o + 1] = toByte(c.y)
            bytes[o + 2] = toByte(c.z); bytes[o + 3] = toByte(c.w)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: gradientResolution, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, gradientResolution, 1),
                        mipmapLevel: 0, withBytes: bytes, bytesPerRow: gradientResolution * 4)
        return texture
    }

    private func sampleGradient(_ sorted: [GradientStop], at p: Double) -> SIMD4<Double> {
        if p <= sorted.first!.position { return sorted.first!.color }
        if p >= sorted.last!.position { return sorted.last!.color }
        for i in 1..<sorted.count {
            if p <= sorted[i].position {
                let a = sorted[i - 1], b = sorted[i]
                let t = (p - a.position) / max(b.position - a.position, 1e-6)
                return a.color + (b.color - a.color) * t
            }
        }
        return sorted.last!.color
    }

    // MARK: - LUT (3D, RGBA)

    func lutTexture(named name: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = lutSize
        descriptor.height = lutSize
        descriptor.depth = lutSize
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        var bytes = [UInt8](repeating: 0, count: lutSize * lutSize * lutSize * 4)
        let denom = Double(lutSize - 1)
        for b in 0..<lutSize {
            for g in 0..<lutSize {
                for r in 0..<lutSize {
                    let input = SIMD3(Double(r) / denom, Double(g) / denom, Double(b) / denom)
                    let out = LUTLooks.apply(name, to: input)
                    let i = (b * lutSize * lutSize + g * lutSize + r) * 4
                    bytes[i + 0] = toByte(out.x); bytes[i + 1] = toByte(out.y)
                    bytes[i + 2] = toByte(out.z); bytes[i + 3] = 255
                }
            }
        }
        bytes.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, lutSize, lutSize, lutSize),
                mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!,
                bytesPerRow: lutSize * 4, bytesPerImage: lutSize * lutSize * 4)
        }
        return texture
    }

    // MARK: - Helpers

    private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
    private func toByte(_ v: Double) -> UInt8 { UInt8(min(255, max(0, v * 255)).rounded()) }

    /// Convert a Float to IEEE 754 half (UInt16) for an .r16Float texture.
    private func float16From(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        let mantissa = bits & 0x7FFFFF
        if exponent <= 0 { return sign }
        if exponent >= 31 { return sign | 0x7C00 }
        return sign | UInt16(exponent << 10) | UInt16(mantissa >> 13)
    }
}

/// CPU color transforms backing the built-in LUTs. Each maps a linear-ish sRGB
/// input color to a graded output, baked into a 3D lookup texture.
enum LUTLooks {
    /// All built-in LUT identifiers, in menu order (nonisolated so descriptors
    /// can reference it).
    static let names = [
        "Identity", "Teal & Orange", "Bleach Bypass", "Warm Film",
        "Cool Shadows", "Vintage", "Noir B&W", "Vibrant",
    ]

    static func apply(_ name: String, to c: SIMD3<Double>) -> SIMD3<Double> {
        switch name {
        case "Teal & Orange": return tealOrange(c)
        case "Bleach Bypass": return bleachBypass(c)
        case "Warm Film": return warmFilm(c)
        case "Cool Shadows": return coolShadows(c)
        case "Vintage": return vintage(c)
        case "Noir B&W": return noir(c)
        case "Vibrant": return vibrant(c)
        default: return clampv(c)
        }
    }

    private static func luma(_ c: SIMD3<Double>) -> Double {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }
    private static func clampv(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(min(1, max(0, c.x)), min(1, max(0, c.y)), min(1, max(0, c.z)))
    }
    private static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }
    private static func sCurve(_ v: Double, _ amount: Double) -> Double {
        let x = min(1, max(0, v))
        return min(1, max(0, x + amount * (x - 0.5) * (1 - abs(2 * x - 1))))
    }

    private static func tealOrange(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = luma(c)
        let shadow = SIMD3(0.0, 0.12, 0.16)
        let highlight = SIMD3(0.18, 0.06, -0.06)
        let tint = mix(shadow, highlight, smoothstep(0.2, 0.8, l))
        return clampv(SIMD3(sCurve(c.x + tint.x, 0.2), sCurve(c.y + tint.y, 0.2), sCurve(c.z + tint.z, 0.2)))
    }
    private static func bleachBypass(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = luma(c)
        let gray = SIMD3(l, l, l)
        let desat = mix(c, gray, 0.55)
        return clampv(SIMD3(sCurve(desat.x, 0.45), sCurve(desat.y, 0.45), sCurve(desat.z, 0.45)))
    }
    private static func warmFilm(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let lifted = c * 0.92 + SIMD3(0.04, 0.03, 0.02)
        return clampv(SIMD3(sCurve(lifted.x + 0.04, 0.15), sCurve(lifted.y + 0.01, 0.15), sCurve(lifted.z - 0.03, 0.15)))
    }
    private static func coolShadows(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = luma(c)
        let cool = SIMD3(c.x - 0.05 * (1 - l), c.y + 0.01 * (1 - l), c.z + 0.1 * (1 - l))
        return clampv(cool)
    }
    private static func vintage(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = luma(c)
        let sepia = SIMD3(l * 1.07 + 0.05, l * 0.97 + 0.03, l * 0.78)
        let blended = mix(c, sepia, 0.4)
        return clampv(blended * 0.93 + SIMD3(0.04, 0.03, 0.03))
    }
    private static func noir(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = sCurve(luma(c), 0.5)
        return SIMD3(l, l, l)
    }
    private static func vibrant(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = luma(c)
        return clampv(mix(SIMD3(l, l, l), c, 1.5))
    }
    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
