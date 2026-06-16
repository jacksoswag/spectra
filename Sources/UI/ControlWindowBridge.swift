import SwiftUI
import AppKit

/// Hands a SwiftUI scene's backing `NSWindow` to the engine once it joins the
/// window hierarchy. The engine tracks Spectra's own control windows (the Studio and
/// Settings) so it can except them from the capture exclusion — they sit *below* the
/// click-through overlay and render *through* the effect chain like any other window
/// (deliberately NOT raised above it; re-adding raising would re-occlude them and
/// break the cursor model). Attach with `.background(ControlWindowConfigurator(engine:))`.
struct ControlWindowConfigurator: NSViewRepresentable {
    let engine: SpectraEngine

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = { window in
            MainActor.assumeIsolated { engine.registerControlWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: WindowReportingView, context: Context) {}
}

/// A zero-size helper view that reports its hosting window whenever it joins one.
final class WindowReportingView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}
