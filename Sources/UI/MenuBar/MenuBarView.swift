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
            Button(engine.isEnabled ? "Pause Spectra" : "Unpause Spectra") {
                engine.toggleEnabled()
            }
            .controlSize(.large)

            Divider()

            presetPicker
            qualityControls

            Divider()

            PerformanceReadout(engine: engine)

            Divider()

            Button("Open Spectra Studio…") {
                openWindow(id: "studio")
                NSApp.activate(ignoringOtherApps: true)
                engine.frontStudioWindow()
            }
            Button("Settings…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit Spectra") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .padding(Theme.Spacing.md)
        .frame(width: 260)
    }

    /// Presets as a single submenu grouped by category. Group headers are a disabled
    /// `Text` plus a `Divider` rather than `Section`, because the NSMenu that backs an
    /// open SwiftUI `Menu` discards `Section` header titles.
    @ViewBuilder
    private var presetPicker: some View {
        Menu(engine.activePresetName.map { "Preset: \($0)" } ?? "Apply a Preset…") {
            ForEach(engine.presets.categories) { category in
                Text(category.displayName)
                ForEach(engine.presets.presets(in: category)) { preset in
                    Button(preset.name) { engine.apply(preset) }
                }
                Divider()
            }
            Button("Browse All in Studio…") {
                openWindow(id: "studio")
                NSApp.activate(ignoringOtherApps: true)
                engine.frontStudioWindow()
            }
        }
    }

    /// Render scale as a native 25%–100% (Native) slider — a fixed fraction of
    /// display resolution (mirrors the Settings and Performance controls).
    @ViewBuilder
    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("Quality")
                Spacer()
                Text(RenderScale.label(engine.settings.renderScale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { engine.settings.renderScale },
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
        HStack {
            Label("\(Int(combined.fps.rounded())) fps", systemImage: "speedometer")
            Spacer()
            Text("\(Int(combined.latencyMilliseconds.rounded())) ms latency")
                .foregroundStyle(.secondary)
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
