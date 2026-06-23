import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One-press styled capture (MAOE §15.4): write the final composited desktop frame straight to
/// a PNG, skipping the Show-in-Screenshots + native-tool dance. The final texture already
/// exists, so this is pure convenience. `DisplayRenderer.captureNextFrame` produces the image;
/// this writes it and reveals it in Finder.
enum StyledOutput {
    static func writePNG(_ image: CGImage) {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("Spectra-\(Int(Date().timeIntervalSince1970)).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
            Log.render.notice("Captured styled frame to \(url.path, privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
