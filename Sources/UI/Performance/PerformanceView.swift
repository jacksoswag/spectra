import SwiftUI

/// Real-time performance dashboard, the permanent left column of the Studio. Live
/// trackers up top, a full timeline per relevant stat below them, then pipeline,
/// shader-cost, render-quality, and per-display detail. Built to read well in a
/// narrow column: trackers and timelines flow in adaptive grids that collapse to a
/// single column when the panel is tight and pack two-up when it's widened.
struct PerformanceView: View {
    @Bindable var engine: SpectraEngine

    /// One rolling buffer per tracked stat. 120 samples at the 0.5s cadence below is
    /// a 60-second window.
    @State private var fpsHistory: [Double] = []
    @State private var gpuHistory: [Double] = []
    @State private var gpuPeakHistory: [Double] = []
    @State private var latencyHistory: [Double] = []
    @State private var cpuHistory: [Double] = []
    @State private var frameIntervalHistory: [Double] = []
    @State private var droppedHistory: [Double] = []
    @State private var vramHistory: [Double] = []

    @State private var costs: [EffectCost] = []
    @State private var profiling = false

    private let maxSamples = 120

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                // A steady 0.5s tick drives both the live trackers and the timeline
                // sampling, so every chart advances even when a stat sits flat.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let snapshot = engine.performance.combined
                    summaryGrid(snapshot)
                        .onChange(of: context.date) { _, _ in record(snapshot) }
                        .onAppear { record(snapshot) }
                }
                timelinesSection
                pipelineSection
                costSection
                renderQualitySection
                perDisplaySection
            }
            .padding(Theme.Spacing.lg)
        }
    }

    private var header: some View {
        Label("Performance", systemImage: "speedometer")
            .font(.title3.weight(.semibold))
    }

    private func summaryGrid(_ s: PerformanceSnapshot) -> some View {
        let budget = budgetMilliseconds
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Theme.Spacing.sm)], spacing: Theme.Spacing.sm) {
            MetricTile(title: "Frame Rate", value: String(format: "%.0f", s.fps), unit: "fps",
                       symbol: "speedometer", tint: s.fps >= 55 ? .green : .orange)
            MetricTile(title: "GPU Time", value: String(format: "%.2f", s.gpuMilliseconds), unit: "ms",
                       symbol: "cpu", tint: s.gpuMilliseconds <= budget ? .green : .orange)
            MetricTile(title: "Latency", value: String(format: "%.1f", s.latencyMilliseconds), unit: "ms",
                       symbol: "timer", tint: s.latencyMilliseconds <= 16 ? .green : .orange)
            MetricTile(title: "Frame Budget", value: String(format: "%.0f", s.budgetFraction(targetMilliseconds: budget) * 100), unit: "%",
                       symbol: "gauge.with.dots.needle.bottom.50percent", tint: .accentColor)
            MetricTile(title: "Dropped", value: String(format: "%.1f", s.droppedPerSecond), unit: "/s",
                       symbol: "exclamationmark.triangle", tint: s.droppedPerSecond < 1 ? .green : .red)
            MetricTile(title: "GPU Passes", value: "\(s.passCount)", unit: "",
                       symbol: "square.stack.3d.up", tint: .accentColor)
            MetricTile(title: "CPU Encode", value: String(format: "%.2f", s.cpuMilliseconds), unit: "ms",
                       symbol: "cpu.fill", tint: .accentColor)
            MetricTile(title: "Frame Interval", value: String(format: "%.1f", s.frameInterval), unit: "ms",
                       symbol: "metronome", tint: .accentColor)
            MetricTile(title: "VRAM", value: String(format: "%.0f", engine.performance.vramMegabytes), unit: "MB",
                       symbol: "memorychip", tint: .accentColor)
            MetricTile(title: "Peak GPU", value: String(format: "%.2f", s.gpuPeakMilliseconds), unit: "ms",
                       symbol: "chart.line.uptrend.xyaxis", tint: .accentColor)
        }
    }

    // MARK: - Timelines

    /// A timeline per relevant stat. Fixed-scale charts (fps, frame interval) keep a
    /// stable y-axis so the line reads against a known target; the rest auto-scale to
    /// their own recent peak so a flat-but-nonzero stat still fills the card.
    private var timelinesSection: some View {
        let budget = budgetMilliseconds
        return InspectorSection(title: "Timelines") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.md)], spacing: Theme.Spacing.md) {
                ChartCard(title: "Frame Rate", values: fpsHistory, maximum: 130, tint: .green, suffix: "fps")
                ChartCard(title: "GPU Time", values: gpuHistory, maximum: max(budget * 1.5, 8), tint: .orange, suffix: "ms", decimals: 1)
                ChartCard(title: "Peak GPU", values: gpuPeakHistory, maximum: max(budget * 2, 12), tint: .pink, suffix: "ms", decimals: 1)
                ChartCard(title: "Latency", values: latencyHistory, maximum: dynamicMax(latencyHistory, floor: 33), tint: .blue, suffix: "ms", decimals: 1)
                ChartCard(title: "CPU Encode", values: cpuHistory, maximum: max(budget, 8), tint: .purple, suffix: "ms", decimals: 2)
                ChartCard(title: "Frame Interval", values: frameIntervalHistory, maximum: 40, tint: .teal, suffix: "ms", decimals: 1)
                ChartCard(title: "Dropped", values: droppedHistory, maximum: dynamicMax(droppedHistory, floor: 5), tint: .red, suffix: "/s", decimals: 1)
                ChartCard(title: "VRAM", values: vramHistory, maximum: dynamicMax(vramHistory, floor: 64), tint: .indigo, suffix: "MB")
            }
        }
    }

    // MARK: - Pipeline analysis

    private var pipelineSection: some View {
        let summary = engine.activePipelineSummary()
        return InspectorSection(title: "Pipeline Analysis") {
            LabeledContent("Effects", value: "\(summary.effectCount)")
            LabeledContent("GPU Passes", value: "\(summary.passCount)")
            LabeledContent("Working Resolution", value: "\(summary.width) × \(summary.height)")
            LabeledContent("Intermediate VRAM", value: String(format: "%.1f MB", summary.intermediateMegabytes))
            Text("The active chain encodes \(summary.passCount) GPU pass(es) across \(summary.effectCount) effect(s), ping-ponging two \(summary.width)×\(summary.height) targets.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Shader cost analysis

    private var costSection: some View {
        InspectorSection(title: "Shader Cost Analysis") {
            HStack {
                Text("Per-effect GPU time, measured in isolation on demand.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    profiling = true
                    DispatchQueue.main.async {
                        costs = engine.profileActiveChain()
                        profiling = false
                    }
                } label: {
                    if profiling { ProgressView().controlSize(.small) }
                    else { Label("Profile", systemImage: "stopwatch") }
                }
                .disabled(profiling)
            }
            if costs.isEmpty {
                Text("Run a profile to measure the active chain.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                let maxCost = costs.map(\.gpuMilliseconds).max() ?? 1
                ForEach(costs) { cost in
                    CostBar(cost: cost, maxCost: maxCost)
                }
            }
        }
    }

    private var renderQualitySection: some View {
        InspectorSection(title: "Render Quality") {
            HStack {
                Text("Scale")
                Slider(value: Binding(
                    get: { engine.settings.renderScale },
                    set: { engine.setRenderScale($0) }),
                    in: RenderScale.min...RenderScale.max)
                Text(RenderScale.label(engine.settings.renderScale))
                    .monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            Text("The effect chain renders at this fixed fraction of the display resolution, upscaled to fit. Lowering it is the strongest speed-up for heavy chains (cost scales with pixel count).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var perDisplaySection: some View {
        InspectorSection(title: "Per-Display") {
            ForEach(engine.displays) { display in
                let s = engine.performance.snapshot(for: display.id)
                HStack {
                    Image(systemName: display.isMain ? "display" : "display.2")
                    VStack(alignment: .leading) {
                        Text(display.name).font(.callout.weight(.medium))
                        Text("\(display.resolutionLabel) · \(display.refreshLabel)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.0f fps · %.1f ms", s.fps, s.gpuMilliseconds))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var budgetMilliseconds: Double {
        let refresh = engine.displays.first(where: { $0.id == engine.selectedDisplayID })?.refreshRate ?? 60
        return 1000.0 / max(refresh, 30)
    }

    private func dynamicMax(_ values: [Double], floor: Double) -> Double {
        max(values.max() ?? floor, floor)
    }

    private func record(_ s: PerformanceSnapshot) {
        push(&fpsHistory, s.fps)
        push(&gpuHistory, s.gpuMilliseconds)
        push(&gpuPeakHistory, s.gpuPeakMilliseconds)
        push(&latencyHistory, s.latencyMilliseconds)
        push(&cpuHistory, s.cpuMilliseconds)
        push(&frameIntervalHistory, s.frameInterval)
        push(&droppedHistory, s.droppedPerSecond)
        push(&vramHistory, engine.performance.vramMegabytes)
    }

    private func push(_ buffer: inout [Double], _ value: Double) {
        buffer.append(value)
        if buffer.count > maxSamples { buffer.removeFirst(buffer.count - maxSamples) }
    }
}

private struct CostBar: View {
    let cost: EffectCost
    let maxCost: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7)).foregroundStyle(Theme.categoryTint(cost.category))
                Text(cost.name).font(.caption.weight(.medium))
                Spacer()
                Text(String(format: "%.2f ms", cost.gpuMilliseconds))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let frac = maxCost > 0 ? cost.gpuMilliseconds / maxCost : 0
                Capsule()
                    .fill(Theme.categoryTint(cost.category).opacity(0.7))
                    .frame(width: max(2, geo.size.width * frac), height: 5)
            }
            .frame(height: 5)
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title2.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.sm)
        .spectraCard()
    }
}

private struct ChartCard: View {
    let title: String
    let values: [Double]
    let maximum: Double
    let tint: Color
    let suffix: String
    var decimals: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(values.last.map { String(format: "%.\(decimals)f %@", $0, suffix) } ?? "—")
                    .font(.caption2.monospacedDigit()).foregroundStyle(tint)
            }
            Canvas { context, size in
                guard values.count > 1 else { return }
                let stepX = size.width / CGFloat(max(values.count - 1, 1))
                var path = Path()
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = size.height * (1 - CGFloat(min(value / maximum, 1)))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(tint), lineWidth: 1.5)
                var fill = path
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.3), tint.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            .frame(height: 64)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity)
        .spectraCard()
    }
}
