import SwiftUI
import simd

/// Bridges effect-instance parameter values to typed SwiftUI bindings. All
/// writes route through `EffectStack.setValue`, so every edit notifies the
/// renderer and persists.
@MainActor
enum ParameterBinding {
    static func value(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> ParameterValue {
        stack[instanceID]?.values[parameter.id] ?? parameter.defaultValue
    }

    static func scalar(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<Double> {
        Binding(
            get: { value(stack, instanceID, parameter).scalarValue ?? parameter.defaultValue.scalarValue ?? 0 },
            set: { stack.setValue(.scalar($0), for: parameter.id, on: instanceID) })
    }

    static func bool(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<Bool> {
        Binding(
            get: { value(stack, instanceID, parameter).boolValue ?? parameter.defaultValue.boolValue ?? false },
            set: { stack.setValue(.bool($0), for: parameter.id, on: instanceID) })
    }

    static func index(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<Int> {
        Binding(
            get: { value(stack, instanceID, parameter).indexValue ?? parameter.defaultValue.indexValue ?? 0 },
            set: { stack.setValue(.index($0), for: parameter.id, on: instanceID) })
    }

    static func color(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<Color> {
        Binding(
            get: {
                let simd = value(stack, instanceID, parameter).colorValue
                    ?? parameter.defaultValue.colorValue ?? SIMD4(1, 1, 1, 1)
                return Color(simd: simd)
            },
            set: { stack.setValue(.color($0.simd4), for: parameter.id, on: instanceID) })
    }

    static func point(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<CGPoint> {
        Binding(
            get: {
                let p = value(stack, instanceID, parameter).pointValue
                    ?? parameter.defaultValue.pointValue ?? SIMD2(0.5, 0.5)
                return CGPoint(x: p.x, y: p.y)
            },
            set: { stack.setValue(.point(SIMD2(Double($0.x), Double($0.y))), for: parameter.id, on: instanceID) })
    }

    /// One component of a vector parameter (count 3 or 4), by axis index.
    static func vectorComponent(
        _ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter,
        axis: Int, count: Int
    ) -> Binding<Double> {
        Binding(
            get: {
                let v = value(stack, instanceID, parameter)
                if count == 3 { let s = v.vector3Value ?? SIMD3(0, 0, 0); return [s.x, s.y, s.z][axis] }
                let s = v.vector4Value ?? SIMD4(0, 0, 0, 0); return [s.x, s.y, s.z, s.w][axis]
            },
            set: { newValue in
                let v = value(stack, instanceID, parameter)
                if count == 3 {
                    var s = v.vector3Value ?? SIMD3(0, 0, 0); s[axis] = newValue
                    stack.setValue(.vector3(s), for: parameter.id, on: instanceID)
                } else {
                    var s = v.vector4Value ?? SIMD4(0, 0, 0, 0); s[axis] = newValue
                    stack.setValue(.vector4(s), for: parameter.id, on: instanceID)
                }
            })
    }

    static func rangeLow(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<Double> {
        Binding(
            get: { value(stack, instanceID, parameter).rangeValue?.0 ?? parameter.defaultValue.rangeValue?.0 ?? 0 },
            set: { lo in
                let hi = value(stack, instanceID, parameter).rangeValue?.1 ?? 1
                stack.setValue(.range(min(lo, hi), hi), for: parameter.id, on: instanceID)
            })
    }

    static func rangeHigh(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<Double> {
        Binding(
            get: { value(stack, instanceID, parameter).rangeValue?.1 ?? parameter.defaultValue.rangeValue?.1 ?? 1 },
            set: { hi in
                let lo = value(stack, instanceID, parameter).rangeValue?.0 ?? 0
                stack.setValue(.range(lo, max(lo, hi)), for: parameter.id, on: instanceID)
            })
    }

    static func curve(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<[CurvePoint]> {
        Binding(
            get: { value(stack, instanceID, parameter).curveValue ?? parameter.defaultValue.curveValue ?? [] },
            set: { stack.setValue(.curve($0), for: parameter.id, on: instanceID) })
    }

    static func gradient(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<[GradientStop]> {
        Binding(
            get: { value(stack, instanceID, parameter).gradientValue ?? parameter.defaultValue.gradientValue ?? [] },
            set: { stack.setValue(.gradient($0), for: parameter.id, on: instanceID) })
    }

    static func lut(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<String> {
        Binding(
            get: { value(stack, instanceID, parameter).lutValue ?? parameter.defaultValue.lutValue ?? "Identity" },
            set: { stack.setValue(.lut($0), for: parameter.id, on: instanceID) })
    }

    static func image(_ stack: EffectStack, _ instanceID: UUID, _ parameter: EffectParameter) -> Binding<String> {
        Binding(
            get: { value(stack, instanceID, parameter).imageValue ?? parameter.defaultValue.imageValue ?? "" },
            set: { stack.setValue(.image($0), for: parameter.id, on: instanceID) })
    }

    // MARK: - Universal parameters

    static func strength(_ stack: EffectStack, _ instanceID: UUID) -> Binding<Double> {
        Binding(
            get: { stack[instanceID]?.universal.strength ?? 1 },
            set: { v in stack.update(instanceID) { $0.universal.strength = v } })
    }

    static func opacity(_ stack: EffectStack, _ instanceID: UUID) -> Binding<Double> {
        Binding(
            get: { stack[instanceID]?.universal.opacity ?? 1 },
            set: { v in stack.update(instanceID) { $0.universal.opacity = v } })
    }

    static func blendAmount(_ stack: EffectStack, _ instanceID: UUID) -> Binding<Double> {
        Binding(
            get: { stack[instanceID]?.universal.blendAmount ?? 1 },
            set: { v in stack.update(instanceID) { $0.universal.blendAmount = v } })
    }

    static func blendMode(_ stack: EffectStack, _ instanceID: UUID) -> Binding<BlendMode> {
        Binding(
            get: { stack[instanceID]?.universal.blendMode ?? .normal },
            set: { v in stack.update(instanceID) { $0.universal.blendMode = v } })
    }

    /// The per-instance random seed (drives stochastic and animated effects).
    static func seed(_ stack: EffectStack, _ instanceID: UUID) -> Binding<Double> {
        Binding(
            get: { Double(stack[instanceID]?.seed ?? 0) },
            set: { v in stack.update(instanceID) { $0.seed = Float(v) } })
    }
}
