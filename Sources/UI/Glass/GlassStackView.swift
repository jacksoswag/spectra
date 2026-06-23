import SwiftUI

/// The "Glass" face of the right panel (selected via the Effects / Glass switcher).
/// A stack of independent toggles for the Liquid Glass system effects — window
/// transparency, tiling, adaptive desktop tint, and per-theme menu-bar / Dock
/// treatments — each driving `SystemEffectsController` directly through the engine,
/// independent of the main effects pipeline and the effect stack.
///
/// Only Window Transparency needs System Integrity Protection partly disabled (yabai's
/// scripting addition); everything else works untouched. An inline note explains that
/// and links to the one-time setup guide.
struct GlassStackView: View {
    @Bindable var engine: SpectraEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                intro
                gateNote
                sipBanner
                Group {
                    transparencyRow
                    tilingRow
                    tintRow
                }
                .disabled(!engine.settings.glassEnabled)
                .opacity(engine.settings.glassEnabled ? 1 : 0.45)
            }
            .padding(Theme.Spacing.lg)
        }
        .background(.background)
        .onAppear { engine.refreshSystemEffectsStatus(needsOpacity: true) }
    }

    /// Shown while the master Glass switch is off: the sub-switches are inert until it's
    /// turned on from the menu bar. Their stored choices are remembered, just suppressed.
    @ViewBuilder
    private var gateNote: some View {
        if !engine.settings.glassEnabled {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text("Turn on Glass from the Spectra menu-bar icon to use these. Your choices are remembered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Intro + SIP

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label("Glass", systemImage: "square.on.square.dashed")
                .font(.title3.weight(.semibold))
            Text("Live desktop treatments: see-through windows, automatic tiling, and an adaptive tint. Turn Glass on from the menu bar, then switch on the pieces you want. They run on their own — no need to press Start.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown only when window opacity is blocked by SIP. The other elements still work,
    /// so this is informational, not a hard wall.
    @ViewBuilder
    private var sipBanner: some View {
        if engine.systemEffectsStatus == .sipRequired {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Window Transparency needs SIP disabled")
                        .font(.callout.weight(.medium))
                    Text("A one-time step in macOS Recovery that no app can do for you. Tiling and tint both work without it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("How to enable…") {
                        openWindow(id: "sip-guide")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.orange.opacity(0.12)))
        }
    }

    // MARK: - Rows

    private var transparencyRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            GlassRow(
                icon: "macwindow", title: "Window Transparency",
                subtitle: "Make every window see-through (via yabai). Needs SIP disabled.",
                note: transparencyStatusNote) {
                Toggle("", isOn: Binding(
                    get: { engine.settings.glassTransparency },
                    set: { engine.setGlassTransparency($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if engine.settings.glassTransparency {
                opacitySliders
            }
        }
    }

    /// Opacity sliders revealed while Window Transparency is on — the focused window and
    /// every other window. Each applies to yabai when its drag ends, so the value can be
    /// dialled in without flooding yabai's command queue mid-drag.
    private var opacitySliders: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            opacitySlider("Active window",
                          get: { engine.settings.glassActiveOpacity },
                          set: { engine.setGlassActiveOpacity($0) })
            opacitySlider("Inactive windows",
                          get: { engine.settings.glassNormalOpacity },
                          set: { engine.setGlassNormalOpacity($0) })
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectraCard()
    }

    @ViewBuilder
    private func opacitySlider(_ label: String, get: @escaping () -> Double,
                               set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((get() * 100).rounded()))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: get, set: set), in: 0.2...1.0,
                   onEditingChanged: { editing in if !editing { engine.commitGlassTransparency() } })
        }
    }

    private var tilingRow: some View {
        GlassRow(
            icon: "rectangle.split.2x1", title: "Window Tiling",
            subtitle: "Auto-arrange windows into a tidy BSP layout (via yabai).") {
            Toggle("", isOn: Binding(
                get: { engine.settings.glassTiling },
                set: { engine.setGlassTiling($0) }))
                .labelsHidden().toggleStyle(.switch)
        }
    }

    private var tintRow: some View {
        GlassRow(
            icon: "drop.halffull", title: "Adaptive Tint",
            subtitle: "Tint the desktop behind glass to match the wallpaper. No setup.") {
            Toggle("", isOn: Binding(
                get: { engine.settings.glassTint },
                set: { engine.setGlassTint($0) }))
                .labelsHidden().toggleStyle(.switch)
        }
    }

    /// A short live status under the transparency row reflecting yabai provisioning.
    private var transparencyStatusNote: (icon: String, color: Color, text: String)? {
        guard engine.settings.glassTransparency else { return nil }
        switch engine.systemEffectsStatus {
        case .opacityReady, .ready, .unknown: return nil
        case .notInstalled: return ("arrow.down.circle", .secondary, "Installing yabai via Homebrew on first enable…")
        case .notRunning: return ("arrow.down.circle", .secondary, "Starting yabai…")
        case .installing: return ("arrow.down.circle", .secondary, "Installing yabai via Homebrew…")
        case .starting: return ("arrow.down.circle", .secondary, "Starting yabai…")
        case .authorizing: return ("lock.shield", .secondary, "Approve the admin prompt to finish enabling window opacity.")
        case .sipRequired: return ("exclamationmark.triangle.fill", .orange, "Blocked by SIP — see the note above. Other elements still work.")
        case .failed(let message): return ("exclamationmark.triangle.fill", .orange, message)
        }
    }
}

/// One Glass element: icon, title, subtitle, an optional live status note, and a
/// trailing control (a switch or a style picker).
private struct GlassRow<Control: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var note: (icon: String, color: Color, text: String)? = nil
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Spacing.sm)
                control
            }
            if let note {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: note.icon).foregroundStyle(note.color)
                    Text(note.text).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 32)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectraCard()
    }
}
