import SwiftUI

/// Real-time performance dashboard: frame/GPU timing, latency, dropped frames,
/// VRAM, refresh tracking, and the render-quality control.
struct PerformanceView: View {
    @Bindable var engine: SpectraEngine
    @State private var fpsHistory: [Double] = []
    @State private var gpuHistory: [Double] = []
    @State private var costs: [EffectCost] = []
    @State private var profiling = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let snapshot = engine.performance.combined
                    summaryGrid(snapshot)
                        .onAppear { record(snapshot) }
                        .onChange(of: snapshot.fps) { _, _ in record(snapshot) }
                }
                charts
                pipelineSection
                costSection
                renderQualitySection
                perDisplaySection
            }
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle("Performance")
    }

    private func summaryGrid(_ s: PerformanceSnapshot) -> some View {
        let budget = budgetMilliseconds
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Theme.Spacing.md)], spacing: Theme.Spacing.md) {
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

    private var charts: some View {
        HStack(spacing: Theme.Spacing.md) {
            ChartCard(title: "Frame Rate", values: fpsHistory, maximum: 130, tint: .green, suffix: "fps")
            ChartCard(title: "GPU Time", values: gpuHistory, maximum: max(budgetMilliseconds * 1.5, 8), tint: .orange, suffix: "ms")
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

    private func record(_ s: PerformanceSnapshot) {
        fpsHistory.append(s.fps); if fpsHistory.count > 120 { fpsHistory.removeFirst() }
        gpuHistory.append(s.gpuMilliseconds); if gpuHistory.count > 120 { gpuHistory.removeFirst() }
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
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .spectraCard()
    }
}

private struct ChartCard: View {
    let title: String
    let values: [Double]
    let maximum: Double
    let tint: Color
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                context.stroke(path, with: .color(tint), lineWidth: 2)
                var fill = path
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.3), tint.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            .frame(height: 100)
            Text(values.last.map { String(format: "%.0f %@", $0, suffix) } ?? "—")
                .font(.caption.monospacedDigit()).foregroundStyle(tint)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity)
        .spectraCard()
    }
}
