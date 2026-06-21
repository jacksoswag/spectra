import SwiftUI

/// Application settings: behaviour, capture, performance, displays, and about.
struct SettingsView: View {
    let engine: SpectraEngine

    var body: some View {
        SettingsForm(engine: engine, settings: engine.settings)
            // Register the Settings window so it's captured and rendered through the
            // effect chain (it sits below the overlay like any other window).
            .background(ControlWindowConfigurator(engine: engine))
    }
}

private struct SettingsForm: View {
    let engine: SpectraEngine
    @Bindable var settings: SettingsStore
    @State private var a11y = SystemAccessibility()
    @State private var showingResetConfirm = false

    var body: some View {
        Form {
            Section("Behaviour") {
                Toggle("Enable Spectra on launch", isOn: $settings.startEnabledOnLaunch)
                Toggle("Show performance in menu bar", isOn: $settings.menuBarShowsPerformance)
                Toggle("Reduce motion in animated effects", isOn: $settings.reduceMotion)
                Toggle("Cover menu bar & Dock", isOn: Binding(
                    get: { settings.coverMenuBarAndDock },
                    set: { engine.setCoverMenuBarAndDock($0) }))
                Text("Raise effects over the menu bar, status items, and Dock so the whole screen is processed (needed for warps to reach the edges). They stay clickable underneath. Press \(GlobalHotKey.panicSwitchLabel) at any time — even from another app — to turn Spectra off if the controls get hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Capture") {
                Picker("Frame Rate", selection: Binding(
                    get: { settings.frameRatePolicy },
                    set: { engine.setFrameRatePolicy($0) })) {
                    ForEach(FrameRatePolicy.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Include cursor in capture", isOn: Binding(
                    get: { settings.showCursorInCapture },
                    set: { engine.setShowCursorInCapture($0) }))
                    .disabled(settings.customCursor)
                Toggle("Stylized cursor (drawn through effects)", isOn: Binding(
                    get: { settings.customCursor },
                    set: { engine.setCustomCursor($0) }))
            }

            Section("Performance") {
                LabeledContent("Intensity") {
                    HStack {
                        Slider(value: Binding(
                            get: { settings.intensity },
                            set: { engine.setIntensity($0) }),
                            in: 0...1)
                        Text("\(Int((settings.intensity * 100).rounded()))%")
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Text("The overall strength of the whole shader, applied on top of each effect's own settings. The presets are tuned for 70%; 100% pushes them about 30% further.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Render scale") {
                    HStack {
                        Slider(value: Binding(
                            get: { settings.renderScale },
                            set: { engine.setRenderScale($0) }),
                            in: RenderScale.min...RenderScale.max)
                        Text(RenderScale.label(settings.renderScale))
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Text("The effect chain renders at this fixed fraction of the display resolution and is upscaled to fit. Heavy chains are bandwidth-bound, so lowering it is the most effective speed-up. Native is full resolution.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Fuse colour passes", isOn: Binding(
                    get: { settings.fuseColorPasses },
                    set: { engine.setFuseColorPasses($0) }))
                Text("Merges back-to-back colour adjustments into one GPU pass. Output is identical; turn off only if a graded look ever appears different.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("VRAM in use", value: String(format: "%.0f MB", engine.performance.vramMegabytes))
            }

            Section("Accessibility") {
                Text("These use the real macOS accessibility settings — applied to your whole screen, not just Spectra.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(a11y.features) { feature in
                    LabeledContent {
                        HStack(spacing: 10) {
                            if let isOn = feature.isOn {
                                Text(isOn ? "On" : "Off")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(isOn ? Color.green : Color.secondary)
                            }
                            Button("Open") { a11y.open(feature) }
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feature.name)
                                Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: feature.icon)
                        }
                    }
                }
            }

            Section("Screen Recording") {
                LabeledContent("Access") {
                    if engine.permissionAuthorized {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not granted", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                Button("Open System Settings…") { ScreenRecordingPermission.openSystemSettings() }
                Button("Re-check & Refresh Displays") { Task { await engine.refreshDisplays() } }
                Label("Captured frames are processed on-device only. Spectra never records, saves, or uploads your screen.",
                      systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Displays") {
                ForEach(engine.displays) { display in
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading) {
                            Text(display.name)
                            Text("\(display.resolutionLabel) · \(display.refreshLabel)\(display.isMain ? " · Main" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Preset").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu(engine.activePresetName(for: display.id) ?? "Choose…") {
                                ForEach(engine.presets.categories) { category in
                                    Menu(category.displayName) {
                                        ForEach(engine.presets.presets(in: category)) { preset in
                                            Button(preset.name) { engine.apply(preset, to: display.id) }
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: 200)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("Each display keeps its own effect stack and preset.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            LicenseSettingsSection(engine: engine)

            Section("About") {
                LabeledContent("Spectra", value: "Version \(AppInfo.versionWithBuild)")
                LabeledContent("Effects", value: "\(engine.registry.descriptors.count) available")
                LabeledContent("Custom Shaders", value: "\(engine.customShaders.shaders.count)")
                Text("A desktop-wide GPU visual effects engine for macOS.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Report a Problem…") { ProblemReporter.report() }
                Button("Reset to Defaults", role: .destructive) { showingResetConfirm = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog("Reset all settings to defaults?", isPresented: $showingResetConfirm, titleVisibility: .visible) {
            Button("Reset to Defaults", role: .destructive) { engine.resetSettingsToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores every Spectra setting to its shipped default. Your effects, presets, and favourites are kept.")
        }
    }
}
