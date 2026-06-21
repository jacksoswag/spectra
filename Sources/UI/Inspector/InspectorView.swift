import SwiftUI

/// Properties panel for the selected effect: identity, universal parameters, and
/// the effect-specific controls grouped by section.
struct InspectorView: View {
    let engine: SpectraEngine
    @Bindable var stack: EffectStack

    private var selection: EffectInstance? { stack.selectedInstance }
    private var descriptor: EffectDescriptor? {
        selection.flatMap { engine.registry.descriptor($0.descriptorID) }
    }

    var body: some View {
        ScrollView {
            if let instance = selection, let descriptor {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    header(instance: instance, descriptor: descriptor)
                    if descriptor.isSystemEffect { systemEffectNote(descriptor: descriptor) }
                    parameterSections(instance: instance, descriptor: descriptor)
                    // System effects drive a controller, not a GPU pass, so blend/strength
                    // don't apply — hide the universal section for them.
                    if !descriptor.isSystemEffect { universalSection(instance: instance) }
                }
                .padding(Theme.Spacing.lg)
            } else {
                placeholder
            }
        }
    }

    private func header(instance: EffectInstance, descriptor: EffectDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Image(systemName: descriptor.iconSystemName)
                    .foregroundStyle(Theme.categoryTint(descriptor.category))
                Text(descriptor.name).font(.title3.bold())
                Spacer()
                Menu {
                    Button("Reset Parameters") { stack.resetParameters(on: instance.id, to: descriptor) }
                    Button("Duplicate") { stack.duplicate(instance.id) }
                    Divider()
                    Button("Remove", role: .destructive) { stack.remove(instance.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text(descriptor.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Setup/availability note for a system effect. Adaptive tint needs nothing; the
    /// yabai-backed rows show how to enable yabai when it isn't ready. Re-probes on
    /// appear so starting yabai after launch clears the note live.
    @ViewBuilder
    private func systemEffectNote(descriptor: EffectDescriptor) -> some View {
        let needsOpacity = descriptor.controllerKind == .windowTransparency
        Group {
            switch descriptor.controllerKind {
            case .windowTransparency, .windowLayout: yabaiNote(needsOpacity: needsOpacity)
            default: EmptyView()
            }
        }
        .onAppear { engine.refreshSystemEffectsStatus(needsOpacity: needsOpacity) }
    }

    @ViewBuilder
    private func yabaiNote(needsOpacity: Bool) -> some View {
        switch engine.systemEffectsStatus {
        case .opacityReady:
            EmptyView()
        case .unknown, .ready:
            if needsOpacity {
                noteBanner("info.circle", .secondary,
                           "Window opacity loads yabai's scripting addition on first enable (one admin prompt). Tiling needs nothing extra.")
            }
        case .notInstalled:
            noteBanner("info.circle", .secondary,
                       "yabai isn't installed. Spectra installs it via Homebrew automatically when you enable this row.")
        case .notRunning:
            noteBanner("info.circle", .secondary,
                       "yabai is installed but not running. Spectra starts it when you enable this row.")
        case .installing:
            noteBanner("arrow.down.circle", .secondary, "Installing yabai via Homebrew…")
        case .starting:
            noteBanner("arrow.down.circle", .secondary, "Starting yabai…")
        case .authorizing:
            noteBanner("lock.shield", .secondary, "Approve the admin prompt to finish enabling window opacity.")
        case .sipRequired:
            noteBanner("exclamationmark.triangle.fill", .orange,
                       "Window opacity needs System Integrity Protection partly disabled (a one-time step in Recovery, which no app can do for you). Tiling and the tint still work without it.")
        case .failed(let message):
            noteBanner("exclamationmark.triangle.fill", .orange, message)
        }
    }

    private func noteBanner(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
    }

    private func universalSection(instance: EffectInstance) -> some View {
        InspectorSection(title: "Universal") {
            LabeledSlider(title: "Strength", value: ParameterBinding.strength(stack, instance.id), range: 0...1, step: 0.01)
            LabeledSlider(title: "Opacity", value: ParameterBinding.opacity(stack, instance.id), range: 0...1, step: 0.01)
            LabeledSlider(title: "Blend Amount", value: ParameterBinding.blendAmount(stack, instance.id), range: 0...1, step: 0.01)
            HStack {
                Text("Blend Mode").font(.callout)
                Spacer()
                Picker("", selection: ParameterBinding.blendMode(stack, instance.id)) {
                    ForEach(BlendMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
            if showsSeed {
                HStack {
                    LabeledSlider(title: "Seed", value: ParameterBinding.seed(stack, instance.id), range: 0...1, step: 0.001)
                    Button { stack.update(instance.id) { $0.seed = Float.random(in: 0..<1) } } label: {
                        Image(systemName: "dice")
                    }
                    .buttonStyle(.borderless).help("Randomize seed")
                }
            }
        }
    }

    /// Stochastic and animated effects expose the random seed so the user can
    /// vary or lock the random pattern.
    private var showsSeed: Bool {
        guard let descriptor else { return false }
        return descriptor.category == .noise || descriptor.isAnimated
    }

    private func parameterSections(instance: EffectInstance, descriptor: EffectDescriptor) -> some View {
        // Parameters in the "Hidden" group are baked-in (tuned, not user-facing) and never shown.
        let visible = descriptor.parameters.filter { $0.group != Self.hiddenGroup }
        let groups = Dictionary(grouping: visible) { $0.group ?? "Parameters" }
        let order = orderedGroupNames(visible)
        return ForEach(order, id: \.self) { name in
            InspectorSection(title: name) {
                ForEach(groups[name] ?? []) { parameter in
                    ParameterControlView(stack: stack, instanceID: instance.id, parameter: parameter)
                }
            }
        }
    }

    /// Sentinel group name for parameters that exist on the GPU (and keep their default/preset
    /// value) but are intentionally not exposed in the inspector.
    static let hiddenGroup = "Hidden"

    private func orderedGroupNames(_ parameters: [EffectParameter]) -> [String] {
        var seen: [String] = []
        for parameter in parameters {
            let name = parameter.group ?? "Parameters"
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private var placeholder: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text("Select an effect").font(.headline).foregroundStyle(.secondary)
            Text("Its properties appear here.").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding()
    }
}

/// A titled inspector section with a card body.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                content
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .spectraCard()
        }
    }
}
