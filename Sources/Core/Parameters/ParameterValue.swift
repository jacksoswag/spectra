import Foundation
import simd

/// A single editable point on a tone curve, in normalised input/output space.
struct CurvePoint: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var x: Double   // input, 0...1
    var y: Double   // output, 0...1

    private enum CodingKeys: String, CodingKey { case x, y }
    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        id = UUID()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
    }
}

/// A color stop on a gradient, positioned in 0...1.
struct GradientStop: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var position: Double
    var color: SIMD4<Double>

    private enum CodingKeys: String, CodingKey { case position, color }
    init(position: Double, color: SIMD4<Double>) { self.position = position; self.color = color }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(Double.self, forKey: .position)
        let rgba = try c.decode([Double].self, forKey: .color)
        guard rgba.count >= 4 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: c.codingPath + [CodingKeys.color],
                debugDescription: "GradientStop color requires 4 elements, got \(rgba.count)"))
        }
        color = SIMD4(rgba[0], rgba[1], rgba[2], rgba[3])
        id = UUID()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(position, forKey: .position)
        try c.encode([color.x, color.y, color.z, color.w], forKey: .color)
    }
}

/// A concrete value held by an effect parameter on a specific effect instance.
///
/// `ParameterValue` is the persisted, type-erased payload. The companion
/// `ParameterControl` (see `EffectParameter`) describes how the value is edited
/// and how many GPU float slots it occupies. Curve, gradient, and LUT values
/// consume no uniform slots: they are baked into auxiliary textures at resolve
/// time and bound to the shader separately.
enum ParameterValue: Codable, Hashable, Sendable {
    case scalar(Double)
    case bool(Bool)
    case index(Int)
    case color(SIMD4<Double>)
    case point(SIMD2<Double>)
    case vector3(SIMD3<Double>)
    case vector4(SIMD4<Double>)
    case range(Double, Double)
    case curve([CurvePoint])
    case gradient([GradientStop])
    case lut(String)            // built-in LUT id

    /// Number of consecutive `float` slots this value writes into the GPU
    /// uniform parameter array.
    var componentCount: Int {
        switch self {
        case .scalar, .bool, .index: 1
        case .point, .range: 2
        case .vector3: 3
        case .color, .vector4: 4
        case .curve, .gradient, .lut: 0   // baked into an auxiliary texture
        }
    }

    /// Whether this value is realised as an auxiliary texture rather than uniforms.
    var isTextureBacked: Bool {
        switch self {
        case .curve, .gradient, .lut: true
        default: false
        }
    }

    /// Flatten into GPU-ready floats, in the order the shader expects.
    var floats: [Float] {
        switch self {
        case .scalar(let v): [Float(v)]
        case .bool(let b): [b ? 1 : 0]
        case .index(let i): [Float(i)]
        case .point(let p): [Float(p.x), Float(p.y)]
        case .color(let c): [Float(c.x), Float(c.y), Float(c.z), Float(c.w)]
        case .vector3(let v): [Float(v.x), Float(v.y), Float(v.z)]
        case .vector4(let v): [Float(v.x), Float(v.y), Float(v.z), Float(v.w)]
        case .range(let lo, let hi): [Float(lo), Float(hi)]
        case .curve, .gradient, .lut: []
        }
    }

    var scalarValue: Double? {
        if case .scalar(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var indexValue: Int? {
        if case .index(let i) = self { return i }
        return nil
    }

    var colorValue: SIMD4<Double>? {
        if case .color(let c) = self { return c }
        return nil
    }

    var pointValue: SIMD2<Double>? {
        if case .point(let p) = self { return p }
        return nil
    }

    var vector3Value: SIMD3<Double>? {
        if case .vector3(let v) = self { return v }
        return nil
    }

    var vector4Value: SIMD4<Double>? {
        if case .vector4(let v) = self { return v }
        return nil
    }

    var rangeValue: (Double, Double)? {
        if case .range(let lo, let hi) = self { return (lo, hi) }
        return nil
    }

    var curveValue: [CurvePoint]? {
        if case .curve(let points) = self { return points }
        return nil
    }

    var gradientValue: [GradientStop]? {
        if case .gradient(let stops) = self { return stops }
        return nil
    }

    var lutValue: String? {
        if case .lut(let id) = self { return id }
        return nil
    }
}

// MARK: - Codable (compact, stable on-disk form)

extension ParameterValue {
    private enum Kind: String, Codable {
        case scalar, bool, index, color, point, vector3, vector4, range, curve, gradient, lut
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value, lo, hi, points, stops, lut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .scalar: self = .scalar(try container.decode(Double.self, forKey: .value))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
        case .index: self = .index(try container.decode(Int.self, forKey: .value))
        case .color:
            let c = try container.decode([Double].self, forKey: .value)
            guard c.count >= 4 else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.value],
                    debugDescription: "color requires 4 elements, got \(c.count)"))
            }
            self = .color(SIMD4(c[0], c[1], c[2], c[3]))
        case .point:
            let p = try container.decode([Double].self, forKey: .value)
            guard p.count >= 2 else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.value],
                    debugDescription: "point requires 2 elements, got \(p.count)"))
            }
            self = .point(SIMD2(p[0], p[1]))
        case .vector3:
            let v = try container.decode([Double].self, forKey: .value)
            guard v.count >= 3 else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.value],
                    debugDescription: "vector3 requires 3 elements, got \(v.count)"))
            }
            self = .vector3(SIMD3(v[0], v[1], v[2]))
        case .vector4:
            let v = try container.decode([Double].self, forKey: .value)
            guard v.count >= 4 else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.value],
                    debugDescription: "vector4 requires 4 elements, got \(v.count)"))
            }
            self = .vector4(SIMD4(v[0], v[1], v[2], v[3]))
        case .range:
            self = .range(try container.decode(Double.self, forKey: .lo),
                          try container.decode(Double.self, forKey: .hi))
        case .curve:
            self = .curve(try container.decode([CurvePoint].self, forKey: .points))
        case .gradient:
            self = .gradient(try container.decode([GradientStop].self, forKey: .stops))
        case .lut:
            self = .lut(try container.decode(String.self, forKey: .lut))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .scalar(let v):
            try container.encode(Kind.scalar, forKey: .kind)
            try container.encode(v, forKey: .value)
        case .bool(let b):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(b, forKey: .value)
        case .index(let i):
            try container.encode(Kind.index, forKey: .kind)
            try container.encode(i, forKey: .value)
        case .color(let c):
            try container.encode(Kind.color, forKey: .kind)
            try container.encode([c.x, c.y, c.z, c.w], forKey: .value)
        case .point(let p):
            try container.encode(Kind.point, forKey: .kind)
            try container.encode([p.x, p.y], forKey: .value)
        case .vector3(let v):
            try container.encode(Kind.vector3, forKey: .kind)
            try container.encode([v.x, v.y, v.z], forKey: .value)
        case .vector4(let v):
            try container.encode(Kind.vector4, forKey: .kind)
            try container.encode([v.x, v.y, v.z, v.w], forKey: .value)
        case .range(let lo, let hi):
            try container.encode(Kind.range, forKey: .kind)
            try container.encode(lo, forKey: .lo)
            try container.encode(hi, forKey: .hi)
        case .curve(let points):
            try container.encode(Kind.curve, forKey: .kind)
            try container.encode(points, forKey: .points)
        case .gradient(let stops):
            try container.encode(Kind.gradient, forKey: .kind)
            try container.encode(stops, forKey: .stops)
        case .lut(let id):
            try container.encode(Kind.lut, forKey: .kind)
            try container.encode(id, forKey: .lut)
        }
    }
}
