import SwiftUI

/// First-run welcome. Explains what Spectra does, points at the on/off control,
/// and offers a one-click starter look. Shown once (gated on
/// `SettingsStore.hasSeenWelcome`) over the Studio.
struct WelcomeView: View {
    @Bindable var engine: SpectraEngine
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 48)).foregroundStyle(Theme.accent)
            Text("Welcome to Spectra")
                .font(.largeTitle.bold())
            Text("Real-time GPU effects across your whole Mac desktop. Build and stack looks, save presets, and turn it all on or off from one control.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                row("play.circle", "Press Start (or ⌥⌘P from anywhere) to turn effects on.")
                row("square.stack.3d.up", "Pick a preset or stack effects in the library.")
                row("lock.fill", "Captured frames are processed on-device only — never recorded or uploaded.")
            }
            .padding(Theme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(.quaternary.opacity(0.4)))

            if !engine.permissionAuthorized {
                Text("Spectra needs Screen Recording to render live across the desktop. You can grant it now or from the banner later.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                if !engine.permissionAuthorized {
                    Button("Grant Screen Recording") { Task { await engine.requestPermission() } }
                }
                Button("Get Started") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
