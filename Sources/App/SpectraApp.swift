import SwiftUI

/// Application entry point. Spectra pairs a persistent menu-bar control surface
/// with the full Studio window, both driven by a single shared `SpectraEngine`.
@main
struct SpectraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine: SpectraEngine? = try? SpectraEngine()

    var body: some Scene {
        Window("Spectra Studio", id: "studio") {
            Group {
                if let engine {
                    StudioView(engine: engine)
                        .task {
                            appDelegate.engine = engine   // so quit runs engine.shutdown()
                            await engine.bootstrap()
                        }
                } else {
                    EngineUnavailableView()
                }
            }
            .frame(minWidth: 740, minHeight: 460)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 854, height: 547)
        .commands { SpectraCommands(engine: engine) }

        MenuBarExtra {
            if let engine {
                MenuBarView(engine: engine)
            } else {
                Button("Quit Spectra") { NSApp.terminate(nil) }
            }
        } label: {
            // Live fps stays on the status item, which can refresh continuously. The
            // panel itself reads per-tick state only inside `PerformanceReadout`, so a
            // refresh re-renders that one row, never the whole panel — leaving the
            // Quality slider and an open Presets submenu undisturbed.
            if let engine {
                MenuBarLabel(engine: engine)
            } else {
                Image(systemName: "sparkles")
            }
        }
        // A popover panel (not the classic NSMenu) so the Quality control can be a
        // real slider — `.menu` only renders buttons/toggles — and so an open submenu
        // is an ordinary view, not an NSMenu that rebuilds and collapses on any change.
        .menuBarExtraStyle(.window)

        // A regular window (not the `Settings` scene) so it reliably reopens after
        // being closed. The macOS `Settings` scene, paired with `SettingsLink`,
        // does not reopen once closed — the window only came back after relaunching
        // the app. Driving an id'd `Window` through `openWindow(id:)` (the same
        // pattern the Studio uses) makes close-then-reopen work every time.
        Window("Settings", id: "settings") {
            if let engine {
                SettingsView(engine: engine)
                    .frame(width: 520, height: 560)
                    .fixedSize()
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Shown when Metal initialisation fails (e.g. no GPU available).
private struct EngineUnavailableView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("Spectra could not start").font(.title2.bold())
            Text("A Metal-capable GPU is required to run Spectra.")
                .foregroundStyle(.secondary)
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(Theme.Spacing.xl)
    }
}

/// Menu-bar commands (keyboard shortcuts surfaced in the app menu).
private struct SpectraCommands: Commands {
    let engine: SpectraEngine?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let engine {
                Button(engine.isEnabled ? "Stop Spectra" : "Start Spectra") {
                    engine.toggleEnabled()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        // Replaces the standard app-menu "Settings…" item that the macOS `Settings`
        // scene used to provide, now that settings live in an id'd `Window`.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
