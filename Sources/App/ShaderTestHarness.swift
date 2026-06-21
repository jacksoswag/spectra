#if DEBUG
import AppKit
@preconcurrency import Metal

/// Debug-only visual harness. With `SPECTRA_SHADERTEST=1` set, on launch this
/// renders built-in presets over test inputs (a synthetic scene + UI card, plus an
/// optional real photo) straight to PNG files, then exits before any window or
/// capture starts. It exists so the stylization looks can be judged off-screen:
/// the live overlay is not screen-capturable, so this is the only way to iterate
/// the shaders with real visual feedback. Never runs in normal use.
///
/// Env:
///   SPECTRA_SHADERTEST=1                 enable
///   SPECTRA_SHADERTEST_OUT=<dir>         output dir (default /tmp/spectra-shadertest)
///   SPECTRA_SHADERTEST_PRESETS=a,b,c     only these preset names (default: Artistic worlds)
///   SPECTRA_SHADERTEST_IMAGE=<path>      add a real image as an extra input
@MainActor
enum ShaderTestHarness {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["SPECTRA_SHADERTEST"] != nil else { return }
        let out = env["SPECTRA_SHADERTEST_OUT"] ?? "/tmp/spectra-shadertest"
        do {
            try run(outDir: out, env: env)
            FileHandle.standardError.write(Data("shadertest: wrote PNGs to \(out)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("shadertest FAILED: \(error)\n".utf8))
        }
        exit(0)
    }

    private static func run(outDir: String, env: [String: String]) throws {
        let context = try MetalContext()
        let shaders = ShaderLibrary(context: context)
        let pool = TexturePool(device: context.device)
        let renderer = EffectChainRenderer(context: context, shaders: shaders, pool: pool)
        let registry = EffectRegistry()
        let auxFactory = AuxTextureFactory(device: context.device)
        let resolver = ChainResolver(registry: registry, composedStore: nil, auxFactory: auxFactory)

        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // Inputs.
        var inputs: [(String, MTLTexture)] = []
        if let scene = texture(from: makeTestCard(width: 3840, height: 2400), device: context.device) {
            inputs.append(("card", scene))
        }
        if let path = env["SPECTRA_SHADERTEST_IMAGE"],
           let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let tex = texture(from: img, device: context.device) {
            inputs.append(("photo", tex))
        }
        guard !inputs.isEmpty else { throw HarnessError.noInput }

        // Which presets.
        let names = env["SPECTRA_SHADERTEST_PRESETS"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let presets = BuiltInPresets.all.filter { preset in
            if let names { return names.contains(preset.name) }
            return preset.category == .artistic
        }

        // Also dump each input unprocessed for an A/B reference.
        for (inputName, tex) in inputs {
            if let png = readbackPNG(of: tex, via: "passthrough_fragment", renderer: nil, shaders: shaders, context: context, pool: pool, input: tex, chain: [], resolver: resolver) {
                try? png.write(to: URL(fileURLWithPath: "\(outDir)/_input-\(inputName).png"))
            }
        }

        for (inputName, tex) in inputs {
            for preset in presets {
                let chain = resolver.resolve(preset.chain)
                guard let png = renderToPNG(chain: chain, input: tex, renderer: renderer, shaders: shaders, context: context, pool: pool) else { continue }
                let safe = preset.name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "'", with: "")
                try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(safe)-\(inputName).png"))
            }
        }
    }

    enum HarnessError: Error { case noInput, encodeFailed }

    // MARK: - Render a resolved chain to a PNG

    private static func renderToPNG(
        chain: [ResolvedEffect], input: MTLTexture, renderer: EffectChainRenderer,
        shaders: ShaderLibrary, context: MetalContext, pool: TexturePool
    ) -> Data? {
        guard let cmd = context.commandQueue.makeCommandBuffer() else { return nil }
        let frame = FrameContext(time: 1.7, frameIndex: 100)
        let result = renderer.encode(into: cmd, input: input, chain: chain, frame: frame, history: nil)
        let png = present(result.outputTexture, via: "present_fragment", shaders: shaders, context: context, into: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        pool.release(result.transientTextures)
        return png?()
    }

    /// Convenience used for the unprocessed input dump (empty chain path).
    private static func readbackPNG(
        of tex: MTLTexture, via fn: String, renderer: EffectChainRenderer?,
        shaders: ShaderLibrary, context: MetalContext, pool: TexturePool,
        input: MTLTexture, chain: [ResolvedEffect], resolver: ChainResolver
    ) -> Data? {
        guard let cmd = context.commandQueue.makeCommandBuffer() else { return nil }
        let png = present(tex, via: fn, shaders: shaders, context: context, into: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        return png?()
    }

    /// Encode a present pass (working float -> 8-bit) into a shared readback texture,
    /// returning a closure that reads it back to PNG once the command buffer completes.
    private static func present(
        _ source: MTLTexture, via fn: String, shaders: ShaderLibrary,
        context: MetalContext, into cmd: MTLCommandBuffer
    ) -> (() -> Data?)? {
        let w = source.width, h = source.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let readback = context.device.makeTexture(descriptor: desc),
              let pipeline = try? shaders.pipeline(fragment: fn, pixelFormat: .rgba8Unorm) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = readback
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        return {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            readback.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return pngData(rgba: bytes, width: w, height: h)
        }
    }

    // MARK: - Image helpers

    private static func texture(from cgImage: CGImage, device: MTLDevice, maxWidth: Int = 6000) -> MTLTexture? {
        let srcW = cgImage.width, srcH = cgImage.height
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1.0, Double(maxWidth) / Double(srcW))
        let w = max(1, Int(Double(srcW) * scale)), h = max(1, Int(Double(srcH) * scale))
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bpr)
        return tex
    }

    private static func pngData(rgba bytes: [UInt8], width: Int, height: Int) -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Synthetic test card (photo-like scene + UI to judge legibility)

    private static func makeTestCard(width w: Int, height h: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let W = CGFloat(w), H = CGFloat(h)

        // Sky gradient (origin bottom-left: high y = top).
        let sky = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: 0.42, green: 0.62, blue: 0.86, alpha: 1),   // top
            CGColor(red: 0.78, green: 0.80, blue: 0.74, alpha: 1),   // horizon
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: H * 0.45), options: [])

        // Sun.
        ctx.setFillColor(CGColor(red: 1.0, green: 0.95, blue: 0.8, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: W * 0.7, y: H * 0.72, width: W * 0.10, height: W * 0.10))

        // Ground.
        ctx.setFillColor(CGColor(red: 0.45, green: 0.55, blue: 0.30, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H * 0.45))
        // Rolling hills (smooth flat-ish color regions for cel/painterly).
        let hills: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
            (0.20, 0.42, 0.55, CGColor(red: 0.30, green: 0.45, blue: 0.24, alpha: 1)),
            (0.65, 0.40, 0.65, CGColor(red: 0.38, green: 0.52, blue: 0.28, alpha: 1)),
            (0.45, 0.30, 0.45, CGColor(red: 0.52, green: 0.62, blue: 0.34, alpha: 1)),
        ]
        for (cx, cy, r, color) in hills {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: W * cx - W * r / 2, y: H * cy - W * r / 2, width: W * r, height: W * r))
        }
        // Soft colored blobs (test painterly brushwork on gradients).
        let blobs: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
            (0.15, 0.80, 0.06, CGColor(red: 0.95, green: 0.45, blue: 0.35, alpha: 0.9)),
            (0.30, 0.68, 0.05, CGColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 0.9)),
            (0.50, 0.82, 0.04, CGColor(red: 0.65, green: 0.40, blue: 0.80, alpha: 0.9)),
        ]
        for (cx, cy, r, color) in blobs {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: W * cx, y: H * cy, width: W * r, height: W * r))
        }

        // A shaded sphere: the canonical cel-shading test. A smooth radial light
        // gradient should break into discrete toon bands under a working cel shader.
        let sphereC = CGPoint(x: W * 0.28, y: H * 0.52)
        let sphereR = W * 0.13
        let sphereGrad = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: 0.98, green: 0.62, blue: 0.50, alpha: 1),
            CGColor(red: 0.45, green: 0.14, blue: 0.18, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: sphereC.x - sphereR, y: sphereC.y - sphereR, width: sphereR * 2, height: sphereR * 2))
        ctx.clip()
        ctx.drawRadialGradient(sphereGrad,
                               startCenter: CGPoint(x: sphereC.x - sphereR * 0.4, y: sphereC.y + sphereR * 0.4), startRadius: sphereR * 0.05,
                               endCenter: sphereC, endRadius: sphereR * 1.25,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()

        // UI: a window card with title bar, traffic lights, and small body text.
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let card = CGRect(x: W * 0.50, y: H * 0.08, width: W * 0.44, height: H * 0.46)
        ctx.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1))
        ctx.fill(card)
        let titleBar = CGRect(x: card.minX, y: card.maxY - 46, width: card.width, height: 46)
        ctx.setFillColor(CGColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1))
        ctx.fill(titleBar)
        let lights: [CGColor] = [
            CGColor(red: 0.99, green: 0.36, blue: 0.34, alpha: 1),
            CGColor(red: 1.0, green: 0.74, blue: 0.18, alpha: 1),
            CGColor(red: 0.24, green: 0.79, blue: 0.30, alpha: 1),
        ]
        for (i, c) in lights.enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: card.minX + 16 + CGFloat(i) * 26, y: titleBar.midY - 7, width: 14, height: 14))
        }
        // Body text at realistic small sizes (the hard case for ink/quantize).
        let lines = [
            ("The quick brown fox jumps over the lazy dog.", 20.0),
            ("Stylized desktops should keep body text readable.", 17.0),
            ("12px UI label  ·  status bar  ·  menu item  ·  tooltip", 13.0),
            ("Lorem ipsum dolor sit amet, consectetur adipiscing.", 15.0),
        ]
        for (i, (text, size)) in lines.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1),
            ]
            NSAttributedString(string: text, attributes: attrs)
                .draw(at: NSPoint(x: card.minX + 18, y: titleBar.minY - 40 - CGFloat(i) * 40))
        }

        // A DARK panel with LIGHT text (the inverse UI case: must not get light smears).
        let darkCard = CGRect(x: W * 0.05, y: H * 0.58, width: W * 0.30, height: H * 0.30)
        ctx.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1))
        ctx.fill(darkCard)
        ctx.setFillColor(CGColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1))
        ctx.fill(CGRect(x: darkCard.minX, y: darkCard.maxY - 38, width: darkCard.width, height: 38))
        let darkLines = [("Dark mode sidebar", 18.0),
                         ("Inbox · Drafts · Sent · Archive", 14.0),
                         ("Settings · Help · Sign out", 13.0)]
        for (i, (text, size)) in darkLines.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1),
            ]
            NSAttributedString(string: text, attributes: attrs)
                .draw(at: NSPoint(x: darkCard.minX + 16, y: darkCard.maxY - 74 - CGFloat(i) * 36))
        }
        NSGraphicsContext.restoreGraphicsState()

        // A row of colorful app-icon squares (fine UI detail).
        let iconColors: [CGColor] = [
            CGColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1),
            CGColor(red: 0.95, green: 0.30, blue: 0.45, alpha: 1),
            CGColor(red: 0.30, green: 0.80, blue: 0.55, alpha: 1),
            CGColor(red: 0.95, green: 0.70, blue: 0.20, alpha: 1),
            CGColor(red: 0.60, green: 0.35, blue: 0.90, alpha: 1),
        ]
        for (i, c) in iconColors.enumerated() {
            ctx.setFillColor(c)
            let r = CGRect(x: W * 0.06 + CGFloat(i) * 90, y: H * 0.07, width: 64, height: 64)
            ctx.fill(r)
        }

        return ctx.makeImage()!
    }
}
#endif
