import SwiftUI

/// License + trial surfaces. All read `engine.license` (the self-contained
/// `LicenseManager`); the Phase 2 backend swap doesn't touch any of this.

/// A Form section for SettingsView: current status, key entry, buy, and remove.
struct LicenseSettingsSection: View {
    @Bindable var engine: SpectraEngine
    @State private var keyField = ""
    @State private var activating = false
    @State private var activationError = false

    var body: some View {
        Section("License") {
            LabeledContent("Status") { statusLabel(engine.license.status) }
            if engine.license.status.wantsPurchasePrompt {
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
        case .trial(let days):
            Label("Trial — \(days) day\(days == 1 ? "" : "s") left", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .trialExpired:
            Label("Trial ended", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
        case .licensed:
            Label("Licensed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .licensedUnverified:
            Label("Licensed (couldn't re-verify)", systemImage: "checkmark.seal").foregroundStyle(.secondary)
        case .unlicensed:
            Label("Not licensed", systemImage: "xmark.seal").foregroundStyle(.red)
        }
    }
}

/// A slim Studio banner during the trial (or after it lapses), with a buy CTA.
struct TrialBanner: View {
    @Bindable var engine: SpectraEngine

    var body: some View {
        if case let .trial(days) = engine.license.status {
            banner(icon: "clock", tint: Theme.accent,
                   text: "\(days) day\(days == 1 ? "" : "s") left in your free trial.")
        } else if engine.license.status == .trialExpired || engine.license.status == .unlicensed {
            banner(icon: "clock.badge.exclamationmark", tint: .orange,
                   text: "Your trial has ended. Buy Spectra to keep using effects.")
        }
    }

    @ViewBuilder
    private func banner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout.weight(.medium))
            Spacer()
            Link("Buy (\(LicenseConfig.price))", destination: LicenseConfig.purchaseURL)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The gate presented when a lapsed trial blocks turning effects on.
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
            Text("Your free trial has ended")
                .font(.title2.bold())
            Text("Buy Spectra for a one-time \(LicenseConfig.price) to keep using effects across your desktop, or enter a license key you already have.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                Button("Not Now") { onDismiss() }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
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
