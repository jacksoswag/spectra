import Foundation
import simd

/// Describes how a parameter is edited in the inspector. The control type also
/// determines the number of GPU float slots the parameter occupies (derived via
/// its default `ParameterValue`).
enum ParameterControl: Codable, Hashable, Sendable {
    /// Continuous value with explicit range and optional snapping step.
    case slider(min: Double, max: Double, step: Double? = nil, unit: String? = nil)
    /// Boolean switch (maps to 0/1 on the GPU).
    case toggle
    /// One-of selection. The stored value is the option index.
    case options([String])
    /// Integer with explicit range, edited via a stepper/slider.
    case integer(min: Int, max: Int)
    /// RGBA color. Occupies four GPU slots.
    case color(supportsOpacity: Bool = true)
    /// Normalised 2D position in [0,1]² (e.g. effect centre). Two GPU slots.
    case point
    /// Angle in degrees (the shader converts to radians as needed).
    case angle
    /// Multi-component vector (3 or 4 floats), edited as labelled fields.
    case vector(count: Int)
    /// A low/high range (two handles). Two GPU slots: lo, hi.
    case range(min: Double, max: Double)
    /// An editable tone curve, baked to a 1D lookup texture.
    case curve
    /// An editable color gradient, baked to a 1D lookup texture.
    case gradient
    /// A color lookup table chosen from built-in options, baked to a 3D texture.
    case lut(options: [String])
    /// A user-supplied image file (e.g. a custom cursor sprite). The picked file is copied
    /// into app support and the value holds its filename; consumed outside the GPU chain.
    case image
}

/// A single tunable input on an effect.
///
/// Parameters are declared in display/GPU order. The renderer assigns each
/// parameter a base slot in the uniform `params[]` array by walking the list and
/// advancing by each value's component count. Shaders read `u.params[slot]` in
/// the same declaration order — this ordering is the binding contract between a
/// `EffectDescriptor` and its Metal function.
struct EffectParameter: Identifiable, Codable, Hashable, Sendable {
    /// Stable key, unique within an effect (e.g. `"amount"`).
    let id: String
    /// Human-readable label.
    let name: String
    let control: ParameterControl
    let defaultValue: ParameterValue
    /// Optional grouping label used to organise the inspector.
    let group: String?
    /// Optional one-line explanation shown as help.
    let help: String?

    init(
        id: String,
        name: String,
        control: ParameterControl,
        defaultValue: ParameterValue,
        group: String? = nil,
        help: String? = nil
    ) {
        self.id = id
        self.name = name
        self.control = control
        self.defaultValue = defaultValue
        self.group = group
        self.help = help
    }

    /// Number of GPU float slots consumed by this parameter.
    var componentCount: Int { defaultValue.componentCount }
}

// MARK: - Convenience constructors

extension EffectParameter {
    static func slider(
        _ id: String,
        _ name: String,
        _ range: ClosedRange<Double>,
        default def: Double,
        step: Double? = nil,
        unit: String? = nil,
        group: String? = nil,
        help: String? = nil
    ) -> EffectParameter {
        EffectParameter(
            id: id, name: name,
            control: .slider(min: range.lowerBound, max: range.upperBound, step: step, unit: unit),
            defaultValue: .scalar(def), group: group, help: help
        )
    }

    static func toggle(
        _ id: String, _ name: String, default def: Bool,
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(id: id, name: name, control: .toggle, defaultValue: .bool(def), group: group, help: help)
    }

    static func options(
        _ id: String, _ name: String, _ options: [String], default def: Int = 0,
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(id: id, name: name, control: .options(options), defaultValue: .index(def), group: group, help: help)
    }

    static func integer(
        _ id: String, _ name: String, _ range: ClosedRange<Int>, default def: Int,
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(
            id: id, name: name, control: .integer(min: range.lowerBound, max: range.upperBound),
            defaultValue: .index(def), group: group, help: help
        )
    }

    static func color(
        _ id: String, _ name: String, default def: SIMD4<Double>, supportsOpacity: Bool = true,
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(
            id: id, name: name, control: .color(supportsOpacity: supportsOpacity),
            defaultValue: .color(def), group: group, help: help
        )
    }

    static func point(
        _ id: String, _ name: String, default def: SIMD2<Double> = SIMD2(0.5, 0.5),
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(id: id, name: name, control: .point, defaultValue: .point(def), group: group, help: help)
    }

    static func angle(
        _ id: String, _ name: String, default def: Double = 0,
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(id: id, name: name, control: .angle, defaultValue: .scalar(def), group: group, help: help)
    }

    static func vector3(
        _ id: String, _ name: String, default def: SIMD3<Double> = SIMD3(0, 0, 0),
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(id: id, name: name, control: .vector(count: 3), defaultValue: .vector3(def), group: group, help: help)
    }

    static func vector4(
        _ id: String, _ name: String, default def: SIMD4<Double> = SIMD4(0, 0, 0, 0),
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(id: id, name: name, control: .vector(count: 4), defaultValue: .vector4(def), group: group, help: help)
    }

    static func range(
        _ id: String, _ name: String, _ bounds: ClosedRange<Double>,
        defaultLow: Double, defaultHigh: Double, group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(
            id: id, name: name, control: .range(min: bounds.lowerBound, max: bounds.upperBound),
            defaultValue: .range(defaultLow, defaultHigh), group: group, help: help)
    }

    static func curve(
        _ id: String, _ name: String, group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(
            id: id, name: name, control: .curve,
            defaultValue: .curve([CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]),
            group: group, help: help)
    }

    static func gradient(
        _ id: String, _ name: String, default stops: [GradientStop]? = nil,
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        let defaultStops = stops ?? [
            GradientStop(position: 0, color: SIMD4(0, 0, 0, 1)),
            GradientStop(position: 1, color: SIMD4(1, 1, 1, 1)),
        ]
        return EffectParameter(
            id: id, name: name, control: .gradient, defaultValue: .gradient(defaultStops),
            group: group, help: help)
    }

    static func lut(
        _ id: String, _ name: String, _ options: [String], default def: String,
        group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(
            id: id, name: name, control: .lut(options: options), defaultValue: .lut(def),
            group: group, help: help)
    }

    static func image(
        _ id: String, _ name: String, group: String? = nil, help: String? = nil
    ) -> EffectParameter {
        EffectParameter(id: id, name: name, control: .image, defaultValue: .image(""), group: group, help: help)
    }
}
