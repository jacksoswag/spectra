import SwiftUI

/// A labelled slider with an inline, editable numeric readout.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(formatted)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }

    private var formatted: String {
        let text: String
        if range.upperBound - range.lowerBound <= 4 {
            text = String(format: "%.2f", value)
        } else {
            text = String(format: "%.0f", value)
        }
        return unit.map { "\(text) \($0)" } ?? text
    }
}

/// A compact normalised XY pad for `point` parameters.
struct XYPad: View {
    @Binding var point: CGPoint   // components in 0...1

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(.quaternary)
                Path { path in
                    path.move(to: CGPoint(x: size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)

                Circle()
                    .fill(Theme.accent)
                    .frame(width: 14, height: 14)
                    .position(x: point.x * size.width, y: point.y * size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    point = CGPoint(
                        x: min(max(drag.location.x / size.width, 0), 1),
                        y: min(max(drag.location.y / size.height, 0), 1))
                })
        }
        .frame(height: 120)
    }
}

/// Renders the correct editor for a single effect parameter.
struct ParameterControlView: View {
    let stack: EffectStack
    let instanceID: UUID
    let parameter: EffectParameter

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            switch parameter.control {
            case let .slider(min, max, step, unit):
                LabeledSlider(title: parameter.name,
                              value: ParameterBinding.scalar(stack, instanceID, parameter),
                              range: min...max, step: step, unit: unit)

            case .toggle:
                Toggle(parameter.name, isOn: ParameterBinding.bool(stack, instanceID, parameter))
                    .font(.callout)

            case let .options(options):
                HStack {
                    Text(parameter.name).font(.callout)
                    Spacer()
                    Picker("", selection: ParameterBinding.index(stack, instanceID, parameter)) {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                            Text(label).tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }

            case let .integer(min, max):
                LabeledSlider(
                    title: parameter.name,
                    value: Binding(
                        get: { Double(ParameterBinding.index(stack, instanceID, parameter).wrappedValue) },
                        set: { ParameterBinding.index(stack, instanceID, parameter).wrappedValue = Int($0.rounded()) }),
                    range: Double(min)...Double(max), step: 1)

            case .color:
                ColorPicker(parameter.name,
                            selection: ParameterBinding.color(stack, instanceID, parameter),
                            supportsOpacity: true)
                    .font(.callout)

            case .point:
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(parameter.name).font(.callout)
                    XYPad(point: ParameterBinding.point(stack, instanceID, parameter))
                }

            case .angle:
                LabeledSlider(title: parameter.name,
                              value: ParameterBinding.scalar(stack, instanceID, parameter),
                              range: 0...360, step: 1, unit: "°")

            case let .vector(count):
                VectorField(title: parameter.name, count: count,
                            component: { axis in ParameterBinding.vectorComponent(stack, instanceID, parameter, axis: axis, count: count) })

            case let .range(min, max):
                RangeSliderField(title: parameter.name,
                                 low: ParameterBinding.rangeLow(stack, instanceID, parameter),
                                 high: ParameterBinding.rangeHigh(stack, instanceID, parameter),
                                 bounds: min...max)

            case .curve:
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(parameter.name).font(.callout)
                    CurveEditor(points: ParameterBinding.curve(stack, instanceID, parameter))
                }

            case .gradient:
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(parameter.name).font(.callout)
                    GradientEditor(stops: ParameterBinding.gradient(stack, instanceID, parameter))
                }

            case let .lut(options):
                HStack {
                    Text(parameter.name).font(.callout)
                    Spacer()
                    Picker("", selection: ParameterBinding.lut(stack, instanceID, parameter)) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }

            if let help = parameter.help {
                Text(help).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Per-axis numeric editor for a 3- or 4-component vector.
struct VectorField: View {
    let title: String
    let count: Int
    let component: (Int) -> Binding<Double>

    private var labels: [String] { count == 3 ? ["X", "Y", "Z"] : ["X", "Y", "Z", "W"] }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(.callout)
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(0..<count, id: \.self) { axis in
                    VStack(spacing: 1) {
                        Text(labels[axis]).font(.caption2).foregroundStyle(.secondary)
                        TextField(labels[axis], value: component(axis), format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 48)
                    }
                }
            }
        }
    }
}

/// A dual-handle range slider with low/high readouts.
struct RangeSliderField: View {
    let title: String
    @Binding var low: Double
    @Binding var high: Double
    let bounds: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: "%.2f – %.2f", low, high))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let width = geo.size.width
                let span = bounds.upperBound - bounds.lowerBound
                let lowX = CGFloat((low - bounds.lowerBound) / span) * width
                let highX = CGFloat((high - bounds.lowerBound) / span) * width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: max(0, highX - lowX), height: 4)
                        .offset(x: lowX)
                    handle.offset(x: lowX - 7).gesture(drag(width: width, span: span, isLow: true))
                    handle.offset(x: highX - 7).gesture(drag(width: width, span: span, isLow: false))
                }
                .frame(height: 20)
            }
            .frame(height: 20)
        }
    }

    private var handle: some View {
        Circle().fill(.white).frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
            .shadow(radius: 1)
    }

    private func drag(width: CGFloat, span: Double, isLow: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            let v = bounds.lowerBound + Double(min(max(value.location.x / width, 0), 1)) * span
            if isLow { low = min(v, high) } else { high = max(v, low) }
        }
    }
}

/// An interactive tone-curve editor: drag handles to move points, tap empty
/// space to add one, double-click an interior point to remove it.
struct CurveEditor: View {
    @Binding var points: [CurvePoint]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(.quaternary.opacity(0.4))
                grid(size: size)
                curvePath(size: size).stroke(Theme.accent, lineWidth: 2)
                ForEach(sortedPoints) { point in
                    Circle().fill(.white)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                        .position(x: CGFloat(point.x) * size.width, y: CGFloat(1 - point.y) * size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            .onTapGesture(count: 2) { addPoint(at: $0, size: size, doubleTap: true) }
            .onTapGesture { addPoint(at: $0, size: size, doubleTap: false) }
        }
        .frame(height: 150)
        .overlay(alignment: .bottomTrailing) {
            Button("Reset") { points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)] }
                .buttonStyle(.borderless).font(.caption2).padding(4)
        }
    }

    private var sortedPoints: [CurvePoint] { points.sorted { $0.x < $1.x } }

    @State private var dragIndex: Int?

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2).onChanged { value in
            let sorted = sortedPoints
            if dragIndex == nil {
                // Grab the nearest handle within range.
                var best = -1; var bestDist = CGFloat.greatestFiniteMagnitude
                for (i, p) in sorted.enumerated() {
                    let px = CGFloat(p.x) * size.width, py = CGFloat(1 - p.y) * size.height
                    let d = hypot(px - value.startLocation.x, py - value.startLocation.y)
                    if d < bestDist { bestDist = d; best = i }
                }
                dragIndex = bestDist < 22 ? best : nil
            }
            guard let index = dragIndex, index < sorted.count else { return }
            let id = sorted[index].id
            guard let actual = points.firstIndex(where: { $0.id == id }) else { return }
            var nx = Double(min(max(value.location.x / size.width, 0), 1))
            let ny = Double(min(max(1 - value.location.y / size.height, 0), 1))
            // Endpoints keep their x pinned to the edges.
            if index == 0 { nx = 0 } else if index == sorted.count - 1 { nx = 1 }
            points[actual].x = nx
            points[actual].y = ny
        }.onEnded { _ in dragIndex = nil }
    }

    private func addPoint(at location: CGPoint, size: CGSize, doubleTap: Bool) {
        let x = Double(min(max(location.x / size.width, 0), 1))
        let y = Double(min(max(1 - location.y / size.height, 0), 1))
        if doubleTap {
            // Remove the nearest interior point if close to the tap.
            let sorted = sortedPoints
            for i in 1..<(max(sorted.count - 1, 1)) where i < sorted.count - 1 {
                let p = sorted[i]
                let d = hypot(CGFloat(p.x) * size.width - location.x, CGFloat(1 - p.y) * size.height - location.y)
                if d < 16, let actual = points.firstIndex(where: { $0.id == p.id }) {
                    points.remove(at: actual)
                    return
                }
            }
        } else {
            points.append(CurvePoint(x: x, y: y))
        }
    }

    private func grid(size: CGSize) -> some View {
        Path { path in
            for i in 1..<4 {
                let x = size.width * CGFloat(i) / 4
                let y = size.height * CGFloat(i) / 4
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }.stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }

    private func curvePath(size: CGSize) -> Path {
        Path { path in
            let sorted = sortedPoints
            guard let first = sorted.first else { return }
            path.move(to: CGPoint(x: CGFloat(first.x) * size.width, y: CGFloat(1 - first.y) * size.height))
            for p in sorted.dropFirst() {
                path.addLine(to: CGPoint(x: CGFloat(p.x) * size.width, y: CGFloat(1 - p.y) * size.height))
            }
        }
    }
}

/// A gradient editor: live preview plus a list of color stops.
struct GradientEditor: View {
    @Binding var stops: [GradientStop]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            LinearGradient(
                gradient: Gradient(stops: sorted.map {
                    .init(color: Color(simd: $0.color), location: $0.position)
                }),
                startPoint: .leading, endPoint: .trailing)
                .frame(height: 22)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                HStack(spacing: Theme.Spacing.sm) {
                    ColorPicker("", selection: Binding(
                        get: { Color(simd: stop.color) },
                        set: { stops[index].color = $0.simd4 }), supportsOpacity: true)
                        .labelsHidden().frame(width: 36)
                    Slider(value: Binding(
                        get: { stops[index].position },
                        set: { stops[index].position = $0 }), in: 0...1)
                    Button { stops.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(stops.count <= 2)
                }
            }
            Button { stops.append(GradientStop(position: 0.5, color: SIMD4(0.5, 0.5, 0.5, 1))) } label: {
                Label("Add Stop", systemImage: "plus")
            }
            .buttonStyle(.borderless).font(.caption)
        }
    }

    private var sorted: [GradientStop] { stops.sorted { $0.position < $1.position } }
}
