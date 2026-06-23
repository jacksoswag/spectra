import SwiftUI

/// License + free-tier surfaces. All read `engine.license` (the self-contained
/// `LicenseManager`); the Phase 2 backend swap doesn't touch any of this.

/// A Form section for SettingsView: current tier, key entry, buy, and remove.
struct LicenseSettingsSection: View {
    @Bindable var engine: SpectraEngine
    @State private var keyField = ""
    @State private var activating = false
    @State private var activationError = false
    @State private var justPurchased = false

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
        .sheet(isPresented: $justPurchased) {
            PurchaseThanksView { justPurchased = false }
        }
    }

    private func activate() {
        activating = true
        activationError = false
        Task {
            let ok = await engine.license.activate(key: keyField)
            activating = false
            activationError = !ok
            if ok { keyField = ""; justPurchased = true }
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
    @State private var purchased = false

    var body: some View {
        // On a successful activation, land on the post-purchase panel in place rather
        // than dismissing, so the just-paid customer always sees the welcome.
        if purchased {
            PurchaseThanksView(onDismiss: onDismiss)
        } else {
            paywall
        }
    }

    private var paywall: some View {
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
            if ok { purchased = true }
        }
    }
}

/// The post-purchase welcome, shown once right after a successful activation (from the
/// paywall gate or the Settings key field). It confirms the unlock and points at the
/// one upgrade that flatters Glass most: a live video wallpaper for the transparent
/// windows and desktop tint to sit over. Aerial is the free, open-source pick.
struct PurchaseThanksView: View {
    let onDismiss: () -> Void
    private static let aerialURL = URL(string: "https://aerialscreensaver.github.io")!

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("Everything's unlocked")
                .font(.title2.bold())
            Text("Thanks for buying Spectra. The full effect library, editing, the composer, and Glass are all yours.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.accent)
                    Text("Pair Glass with a live wallpaper").font(.callout.weight(.semibold))
                }
                Text("Glass makes your windows transparent and tints the desktop, so it works best over something that moves. Aerial is a free, open-source app that plays Apple's aerial videos as a live desktop wallpaper behind your windows.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Get Aerial (free)", destination: Self.aerialURL)
                    .font(.callout.weight(.medium))
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.accent.opacity(0.10)))

            Button("Start exploring") { onDismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 470)
    }
}
