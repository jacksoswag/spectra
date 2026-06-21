import SwiftUI

/// A slim, dismissible banner for transient engine status: a capture/launch
/// failure (`startupError`) or an auto-recovery notice (`lastRecoveryMessage`).
/// Without this, those messages were set on the engine but never shown, so a
/// failed capture start or an auto-disabled overlay was invisible to the user.
struct StatusBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(.orange)
            Text(message)
                .font(.callout.weight(.medium))
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
