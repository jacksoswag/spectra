import SwiftUI

/// A slim, non-blocking banner shown when Screen Recording isn't granted yet.
/// The workspace stays fully usable — effects preview on the wallpaper — and this
/// only explains what's needed to render live across the desktop.
struct PermissionBanner: View {
    @Bindable var engine: SpectraEngine

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Preview works now. Grant Screen Recording to render effects live across your desktop.")
                    .font(.callout.weight(.medium))
                Text("Spectra captures your displays only while it is turned on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant Access") { Task { await engine.requestPermission() } }
                .buttonStyle(.borderedProminent)
            Button("System Settings") { ScreenRecordingPermission.openSystemSettings() }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.accent.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}
