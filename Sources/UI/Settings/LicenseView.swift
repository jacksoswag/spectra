import SwiftUI

/// License + free-tier surfaces. All read `engine.license` (the self-contained
/// `LicenseManager`); the Phase 2 backend swap doesn't touch any of this.

/// A Form section for SettingsView: current tier, key entry, buy, and remove.
struct LicenseSettingsSection: View {
    @Bindable var engine: SpectraEngine
    @State private var keyField = ""
    @State private var activating = false
    @State private var activationError = false

    var body: some View {
        Section("License") {
            LabeledContent("Status") { statusLabel(engine.license.status) }
            if engine.license.status.wantsUpgradePrompt {
                Text("Free tier: apply the cinematic presets with the intensity and quality controls. A license unlocks the full \(engine.registry.descriptors.count)-effect library, editing, the composer, all presets, and Glass.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("SPECTRA-XXXX-XXXX-XXXX", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .disabled(activating)
                    Button("Activate") { activate() }
                        .disabled(activating || keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if activationError {
                    Text("That key wasn't recognised. Check it and try again.")
                        .font(.caption).foregroundStyle(.red)
                }
                Link("Buy Spectra (\(LicenseConfig.price))", destination: LicenseConfig.purchaseURL)
            } else {
                Button("Remove License", role: .destructive) { engine.license.deactivate() }
            }
        }
    }

    private func activate() {
        activating = true
        activationError = false
        Task {
            let ok = await engine.license.activate(key: keyField)
            activating = false
            activationError = !ok
            if ok { keyField = "" }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: LicenseStatus) -> some View {
        switch status {
        case .free:
            Label("Free tier", systemImage: "lock").foregroundStyle(.secondary)
        case .licensed:
            Label("Licensed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .licensedUnverified:
            Label("Licensed (couldn't re-verify)", systemImage: "checkmark.seal").foregroundStyle(.secondary)
        }
    }
}

/// A slim Studio banner shown in the free tier with an unlock CTA.
struct UpgradeBanner: View {
    @Bindable var engine: SpectraEngine

    var body: some View {
        if engine.license.status.wantsUpgradePrompt {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "lock.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Free tier — the cinematic presets only.").font(.callout.weight(.medium))
                    Text("Unlock the full library, editing, the composer, and Glass.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Unlock") { engine.license.promptGate() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.accent.opacity(0.10))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// The paywall sheet, presented when a gated (paid) action is attempted in the free tier.
struct LicenseGateView: View {
    @Bindable var engine: SpectraEngine
    let onDismiss: () -> Void
    @State private var keyField = ""
    @State private var activating = false
    @State private var activationError = false

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Unlock the full Spectra")
                .font(.title2.bold())
            Text("The free tier applies the cinematic presets with the intensity and quality controls. Unlock everything else for a one-time \(LicenseConfig.price):")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                row("square.stack.3d.up", "All \(engine.registry.descriptors.count) effects and every preset")
                row("slider.horizontal.3", "Build and edit your own stacks and tune every parameter")
                row("wand.and.stars", "The visual composer and custom shader import")
                row("macwindow", "Glass: live window transparency and the desktop tint")
            }
            .padding(Theme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(.quaternary.opacity(0.4)))

            HStack {
                TextField("SPECTRA-XXXX-XXXX-XXXX", text: $keyField)
                    .textFieldStyle(.roundedBorder)
                    .disabled(activating)
                Button("Activate") { activate() }
                    .disabled(activating || keyField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if activationError {
                Text("That key wasn't recognised. Check it and try again.")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack {
                Link("Buy Spectra (\(LicenseConfig.price))", destination: LicenseConfig.purchaseURL)
                    .buttonStyle(.borderedProminent)
                Button("Keep Free Tier") { onDismiss() }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 470)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func activate() {
        activating = true
        activationError = false
        Task {
            let ok = await engine.license.activate(key: keyField)
            activating = false
            activationError = !ok
            if ok { onDismiss() }
        }
    }
}
