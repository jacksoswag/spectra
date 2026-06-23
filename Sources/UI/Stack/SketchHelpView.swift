import SwiftUI

/// One-time help shown the first time the Pencil Sketch draw-on-screen effect appears in the stack
/// (gated on `SettingsStore.hasSeenSketchHelp`). Explains the two controls — drag to draw,
/// double-click to erase — then never shows again.
struct SketchHelpView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "pencil.tip")
                .font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text("Drawing on Screen")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                row("hand.draw", "Press and drag to draw. The line starts once you move, so a single click won't leave a dot.")
                row("trash", "Double-click anywhere to erase everything and start fresh.")
            }
            .padding(Theme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(.quaternary.opacity(0.4)))

            Button("Got it") { onDismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 360)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
