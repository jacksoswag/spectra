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
                MenuBarStatusLabel(engine: engine)
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

        // The contextual SIP-education window, opened only when the user enables
        // Glass while SIP is on (see SpectraEngine.sipGuideRequested). Dismissing it
        // clears the engine flag.
        Window("Window Transparency & SIP", id: "sip-guide") {
            if let engine {
                SIPGuideWindowContent(engine: engine)
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Hosts the SIP guide so it can clear the engine flag and close its own window
/// (the `dismissWindow` environment value is only available inside a View).
private struct SIPGuideWindowContent: View {
    let engine: SpectraEngine
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        SIPRequiredView {
            engine.dismissSIPGuide()
            dismissWindow(id: "sip-guide")
        }
    }
}

/// The always-present status-item label, plus the Dock-reopen bridge. A Dock-icon click
/// posts `.spectraReopen`; SwiftUI's `openWindow` recreates the closed Studio `Window`
/// scene — which AppKit's own reopen does NOT do for a SwiftUI singleton window — so the
/// Dock icon reopens the Studio exactly like the menu item. This must live on the menu-bar
/// label because that view is always alive: the Studio's own content can't reopen itself
/// once it has been closed. (The engine's `.spectraReopen` observer still raises an
/// already-open-but-buried Studio; this adds the create-when-closed case it can't handle.)
private struct MenuBarStatusLabel: View {
    let engine: SpectraEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabel(engine: engine)
            .onReceive(NotificationCenter.default.publisher(for: .spectraReopen)) { _ in
                openWindow(id: "studio")
                NSApp.activate(ignoringOtherApps: true)
                engine.frontStudioWindow()
            }
            // Present the SIP-education window when enabling Glass hits a SIP block.
            .onChange(of: engine.sipGuideRequested) { _, requested in
                guard requested else { return }
                openWindow(id: "sip-guide")
                NSApp.activate(ignoringOtherApps: true)
            }
            // A gated action from the menu bar (e.g. Glass) requests the paywall, which
            // lives as a Studio sheet — surface the Studio so it can show even when closed.
            .onChange(of: engine.license.gatePrompted) { _, prompted in
                guard prompted else { return }
                openWindow(id: "studio")
                NSApp.activate(ignoringOtherApps: true)
                engine.frontStudioWindow()
            }
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
