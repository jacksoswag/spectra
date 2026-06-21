import SwiftUI

/// The menu-bar control surface, presented as a compact popover panel
/// (`.menuBarExtraStyle(.window)`). The panel hosts a native Quality slider — which
/// the classic NSMenu style can't render — and, because it's an ordinary SwiftUI
/// view hierarchy rather than a rebuilt NSMenu, an open Presets submenu no longer
/// collapses the instant an unrelated value changes.
///
/// Live performance is read only inside `PerformanceReadout`, never in this panel's
/// body. SwiftUI's Observation tracks reads per view, so a per-tick stats refresh
/// invalidates just that one row, leaving the slider and an open submenu untouched.
/// (The old `.menu` surface rebuilt the whole NSMenu on every tick because the body
/// read `performance.combined` directly — which is what made the dropdowns vanish.)
struct MenuBarView: View {
    @Bindable var engine: SpectraEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button(engine.isEnabled ? "Stop Spectra" : "Start Spectra") {
                engine.toggleEnabled()
            }
            .controlSize(.large)
            .help("Toggle effects on or off (\(GlobalHotKey.toggleLabel) from anywhere)")

            Divider()

            PresetPicker(engine: engine, openStudio: {
                openWindow(id: "studio")
                NSApp.activate(ignoringOtherApps: true)
                engine.frontStudioWindow()
            })
            intensityControls
            QualityControl(engine: engine)

            Divider()

            PerformanceReadout(engine: engine)

            Divider()

            HStack {
                Button("Open Studio") {
                    openWindow(id: "studio")
                    NSApp.activate(ignoringOtherApps: true)
                    engine.frontStudioWindow()
                }
                Spacer()
                Toggle("Glass", isOn: Binding(
                    get: { engine.settings.glassEnabled },
                    set: { engine.setGlassEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
            }
            HStack {
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Report a Problem…") { ProblemReporter.report() }
            }
            Button("Quit Spectra") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .padding(Theme.Spacing.md)
        .frame(width: 240)
    }


    /// Overall shader intensity as a 0%–100% slider. Scales every effect's strength
    /// at render time (it never edits the stack), so the active-preset label above is
    /// unaffected. 100% (the default) is the look the presets ship at; lower values
    /// fade every effect down toward off.
    @ViewBuilder
    private var intensityControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("Intensity")
                Spacer()
                Text("\(Int((engine.settings.intensity * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { engine.settings.intensity },
                    set: { engine.setIntensity($0) }),
                in: 0...1)
        }
    }

}

/// Presets grouped by category, presented INLINE (an expanding disclosure) rather
/// than a nested SwiftUI `Menu`. A `Menu` inside the `.window`-style MenuBarExtra
/// popover never opens — the panel isn't a key window that can host the NSMenu the
/// `Menu` tries to present, so clicking it did nothing. An inline list is pure
/// SwiftUI and always works; it keeps the active-preset name as the header.
private struct PresetPicker: View {
    @Bindable var engine: SpectraEngine
    var openStudio: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(engine.activePresetName.map { "Preset: \($0)" } ?? "Apply a Preset…")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }

            if expanded {
                // Categories as a 2-column table (the four built-ins land as a clean 2x2),
                // each column's title and presets centred. A LazyVGrid reports a definite
                // height, so the size-to-fit MenuBarExtra panel grows to host the whole grid
                // with no scrolling — unlike a ScrollView, which collapses to ~0 here.
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: Theme.Spacing.sm),
                              GridItem(.flexible(), spacing: Theme.Spacing.sm)],
                    alignment: .center, spacing: Theme.Spacing.md
                ) {
                    ForEach(engine.presets.categories) { category in
                        VStack(spacing: Theme.Spacing.xs) {
                            Text(category.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(engine.presets.presets(in: category)) { preset in
                                Button(preset.name) {
                                    engine.apply(preset)
                                    withAnimation(.easeInOut(duration: 0.15)) { expanded = false }
                                }
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(.top, Theme.Spacing.xs)

                Divider()
                Button("Browse All in Studio…", action: openStudio)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

/// Render scale as a 25%–Native slider, isolated into its own view. While Auto is
/// on, the governor moves `effectiveRenderScale` live; keeping this in its own view
/// means those updates re-render only this row, never the whole panel (which would
/// collapse an open Presets submenu). Dragging the slider hands control back from
/// the governor (`setRenderScale` turns Auto off).
private struct QualityControl: View {
    @Bindable var engine: SpectraEngine

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("Quality")
                Spacer()
                Text(engine.settings.autoQuality
                     ? "Auto · \(RenderScale.label(engine.effectiveRenderScale))"
                     : RenderScale.label(engine.settings.renderScale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { engine.effectiveRenderScale },
                    set: { engine.setRenderScale($0) }),
                in: RenderScale.min...RenderScale.max)
        }
    }
}

/// Live fps / latency, isolated into its own view so the per-tick refresh that
/// updates these numbers re-renders only this row — not the whole panel — and so
/// can never disturb the Quality slider or an open Presets submenu.
private struct PerformanceReadout: View {
    @Bindable var engine: SpectraEngine

    var body: some View {
        let combined = engine.performance.combined
        HStack(spacing: Theme.Spacing.sm) {
            Label("\(Int(combined.fps.rounded())) fps", systemImage: "speedometer")
            Text("- \(Int(combined.latencyMilliseconds.rounded())) ms")
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Auto", isOn: Binding(
                get: { engine.settings.autoQuality },
                set: { engine.setAutoQuality($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .help("Automatically adjust quality to hold ~54 fps")
        }
        .font(.callout)
        .monospacedDigit()
    }
}

/// The always-visible menu-bar status item. Live performance is shown *here* (a
/// status-item label refreshes continuously without touching the panel) as well as
/// in the panel's isolated `PerformanceReadout`.
struct MenuBarLabel: View {
    @Bindable var engine: SpectraEngine

    var body: some View {
        if engine.settings.menuBarShowsPerformance && engine.isEnabled {
            Label("\(Int(engine.performance.combined.fps.rounded())) fps", systemImage: "sparkles")
        } else {
            Image(systemName: "sparkles")
        }
    }
}
