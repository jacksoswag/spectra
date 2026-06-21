import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// The one-time education surface shown when the user enables Glass (window
/// transparency) while System Integrity Protection is on. Window opacity is the
/// single feature that needs SIP partly disabled; everything else in Spectra
/// works without it. Presented only on the Glass-enable action, never as a
/// standalone button, so the majority who never use Glass never see SIP advertised.
struct SIPRequiredView: View {
    let onDone: () -> Void

    /// yabai's own wiki page, which carries the current, hardware-correct Recovery
    /// commands (they differ by Apple Silicon vs Intel and by macOS version, so we
    /// link to the source of truth rather than hardcode a command that can go stale).
    private static let guideURL = URL(string: "https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header

                section("What it unlocks", icon: "macwindow", tint: .blue) {
                    Text("Live window transparency and blur (Glass). Everything else — all the shader effects, the colour grade, the adaptive desktop tint, window tiling — already works without any SIP change.")
                }

                section("Why it's safe to back out", icon: "checkmark.shield", tint: .green) {
                    bullet("Spectra is fully functional without it; only window transparency stays off.")
                    bullet("It's reversible: re-enable SIP from Recovery the same way you disabled it.")
                    bullet("Nothing changes on your Mac without an explicit admin password prompt.")
                }

                section("The real tradeoff", icon: "exclamationmark.triangle", tint: .orange) {
                    Text("Disabling SIP lowers a core macOS security protection (it's what lets a tool like yabai modify other apps' windows). Leave it on if you're unsure — Glass is a power-user extra, not core to Spectra.")
                }

                section("How to do it", icon: "qrcode", tint: .secondary) {
                    Text("It's a one-time step in macOS Recovery. The exact commands depend on your Mac (Apple Silicon vs Intel) and macOS version, and you can't copy-paste in Recovery — so scan this on your phone to follow yabai's current official guide:")
                    HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                        qrImage
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Link(destination: Self.guideURL) {
                                Label("Open yabai's SIP guide", systemImage: "safari")
                            }
                            Text(Self.guideURL.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 520, height: 600)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.md)
            .background(.bar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36)).foregroundStyle(Theme.accent)
            Text("Window transparency needs SIP partly disabled")
                .font(.title2.bold())
            Text("Glass is on, and its window transparency is the one feature that requires turning off part of System Integrity Protection. Tiling and the desktop tint are already working.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section(_ title: String, icon: String, tint: Color, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: icon)
                .font(.headline).foregroundStyle(tint)
            content()
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
    }

    private var qrImage: some View {
        Group {
            if let image = Self.qr(from: Self.guideURL.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(.quaternary)
                    .frame(width: 140, height: 140)
                    .overlay { Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }
    }

    /// Render a QR for `string` as an `NSImage` (CoreImage's generator).
    private static func qr(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
