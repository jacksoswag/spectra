import SwiftUI
@preconcurrency import Metal
import MetalKit
import QuartzCore

/// Drives a live preview of the processed result for one display by running the
/// effect chain on the most recent captured frame. Reuses `EffectChainRenderer`
/// with a private texture pool.
@MainActor
final class PreviewRenderer: NSObject, MTKViewDelegate {
    private let engine: SpectraEngine
    private let chainRenderer: EffectChainRenderer
    private let pool: TexturePool
    /// A private command queue so the preview never head-of-lines the overlay's
    /// frames: both used to share `context.commandQueue`, so a preview command
    /// buffer (and its `currentDrawable` wait) could delay the overlay's present.
    private let commandQueue: MTLCommandQueue
    /// One-deep gate: the preview drops a frame rather than queue GPU work ahead of
    /// the overlay. Balanced signal in the completion handler.
    private let inFlight = DispatchSemaphore(value: 1)
    private var frameIndex: Float = 0
    private var historyTexture: MTLTexture?
    var displayID: CGDirectDisplayID?
    /// When set, the preview renders this chain instead of the display's live
    /// chain (used by the composer to preview an in-progress pipeline).
    var chainProvider: (() -> [ResolvedEffect])?

    init(engine: SpectraEngine) {
        self.engine = engine
        self.pool = TexturePool(device: engine.context.device)
        self.chainRenderer = EffectChainRenderer(
            context: engine.context, shaders: engine.shaderLibrary, pool: pool)
        self.commandQueue = engine.context.device.makeCommandQueue() ?? engine.context.commandQueue
        super.init()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            renderFrame(in: view)
        }
    }

    @MainActor
    private func renderFrame(in view: MTKView) {
        // Don't spend GPU on a preview the user can't see. While the Studio window
        // is hidden behind another window, on another Space, or miniaturised, the
        // MTKView keeps ticking but each draw early-returns and encodes nothing — so
        // the preview stops competing with the overlay for the GPU and main thread.
        guard let window = view.window,
              window.occlusionState.contains(.visible), !window.isMiniaturized else { return }
        guard let displayID, let input = engine.previewInputTexture(for: displayID) else { return }

        // While Spectra is live, the overlay already shows the real processed result
        // across the whole desktop, so the wallpaper preview is redundant — and
        // rendering it (a second full-chain encode at up to 30fps) is pure heat. Pause
        // it whenever the overlay is active; the composer preview (`chainProvider`)
        // still runs so in-progress edits stay live.
        if chainProvider == nil && engine.isEnabled { return }

        // Drop this preview frame rather than queue work ahead of the overlay. Gate
        // first, before claiming a drawable, so a dropped frame never strands one.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { inFlight.signal(); return }
        let chain = chainProvider?() ?? engine.resolvedChain(for: displayID)
        frameIndex += 1
        let clock = FrameContext.liveClock()
        let frame = FrameContext(
            time: engine.currentTime(), frameIndex: frameIndex,
            clockSeconds: clock.clockSeconds,
            year: clock.year, month: clock.month, day: clock.day)
        let needsHistory = chain.contains { $0.descriptor.needsHistory }
        let result = chainRenderer.encode(
            into: commandBuffer, input: input, chain: chain, frame: frame,
            history: needsHistory ? historyTexture : nil)
        if needsHistory {
            updateHistory(from: result.outputTexture, in: commandBuffer)
        } else {
            historyTexture = nil
        }

        if let pipeline = try? engine.shaderLibrary.pipeline(
            fragment: "present_fragment", pixelFormat: view.colorPixelFormat) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            descriptor.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(result.outputTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        let transient = result.transientTextures
        commandBuffer.addCompletedHandler { [pool, inFlight] _ in
            pool.release(transient)
            inFlight.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Copy the chain output into the persistent history texture for next frame.
    private func updateHistory(from output: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        if historyTexture?.width != output.width || historyTexture?.height != output.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: MetalContext.workingPixelFormat,
                width: output.width, height: output.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            historyTexture = engine.context.device.makeTexture(descriptor: descriptor)
        }
        guard let history = historyTexture, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: output, to: history)
        blit.endEncoding()
    }
}

private struct PreviewMetalView: NSViewRepresentable {
    let engine: SpectraEngine
    let displayID: CGDirectDisplayID?
    let fps: Int
    var chainProvider: (() -> [ResolvedEffect])?

    func makeCoordinator() -> PreviewRenderer { PreviewRenderer(engine: engine) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: engine.context.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = fps
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        context.coordinator.displayID = displayID
        context.coordinator.chainProvider = chainProvider
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.displayID = displayID
        context.coordinator.chainProvider = chainProvider
        view.preferredFramesPerSecond = fps
    }
}

/// Live preview pane with a tasteful checkerboard backing and an idle state.
struct PreviewView: View {
    let engine: SpectraEngine
    let displayID: CGDirectDisplayID?
    /// Optional override chain (the composer previews its in-progress pipeline).
    var chainProvider: (() -> [ResolvedEffect])?
    /// When false, suppress the "add effects" idle hint (e.g. composer preview).
    var showsIdleHint: Bool = true

    /// The preview pane is a small editing aid, not the live output — 30fps reads
    /// smoothly for animated effects and halves the preview's per-second encode
    /// cost, leaving more GPU/main-thread headroom for the overlay it sits beside.
    private var fps: Int { 30 }

    var body: some View {
        ZStack {
            CheckerboardBackground()
            if displayID != nil {
                PreviewMetalView(engine: engine, displayID: displayID, fps: fps, chainProvider: chainProvider)
            }
            if showsIdleHint, chainProvider == nil, engine.activeStack?.effects.isEmpty ?? true {
                idleOverlay
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Color.primary.opacity(0.1)))
    }

    private var idleOverlay: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Pick a preset to begin")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Apply a preset for an instant look, or add effects to build your own.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
        .allowsHitTesting(false)
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 16
            let cols = Int(size.width / tile) + 1
            let rows = Int(size.height / tile) + 1
            for row in 0..<rows {
                for col in 0..<cols {
                    if (row + col) % 2 == 0 {
                        let rect = CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                        context.fill(Path(rect), with: .color(.gray.opacity(0.10)))
                    }
                }
            }
        }
        .background(Color.black.opacity(0.6))
    }
}
