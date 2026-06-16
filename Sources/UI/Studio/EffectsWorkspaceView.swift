import SwiftUI

/// Compact live performance readout shown beneath the preview. Reflects the
/// selected display when one is targeted, otherwise the combined figures.
struct PreviewStatusBar: View {
    @Bindable var engine: SpectraEngine

    private var snapshot: PerformanceSnapshot {
        guard let id = engine.selectedDisplayID else { return engine.performance.combined }
        return engine.performance.snapshot(for: id)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            metric("FPS", String(format: "%.0f", snapshot.fps))
            metric("GPU", String(format: "%.1f ms", snapshot.gpuMilliseconds))
            metric("Latency", String(format: "%.1f ms", snapshot.latencyMilliseconds))
            metric("Passes", "\(snapshot.passCount)")
            Spacer()
            if engine.isEnabled {
                Label("Live", systemImage: "livephoto").foregroundStyle(.green)
            } else {
                Label("Preview only", systemImage: "eye").foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.sm)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value)
        }
    }
}

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
