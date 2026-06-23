#!/usr/bin/env swift
// Generates the three comic click sprites (MAOE §7.1) — POP, BANG, POW — as bold 1960s–70s
// pop-art bursts: radiating ink speed-lines behind a spiky star with a thick black outline, a
// Ben-Day halftone speckle in the star, and chunky slanted comic lettering with a cream outline +
// hard offset ink shadow. Each word gets its own star/letter colours (red POP, gold BANG, blue POW)
// so fx_int_powSprite can pick one at random per click. Transparent background — the star reads as
// the panel, no opaque rectangle on the desktop. Run: swift Scripts/gen_interaction_sprites.swift
import AppKit
import CoreGraphics
import CoreText

let outDir = "Resources/InteractionSprites"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let ptSize = 96.0, scale = 2.0          // 192 px source — room for crisp lettering
let px = Int(ptSize * scale)
let cs = CGColorSpaceCreateDeviceRGB()
let ink = CGColor(red: 0.08, green: 0.06, blue: 0.05, alpha: 1)
let C = 48.0                            // centre

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func drawBurst(_ word: String, starInner: CGColor, starOuter: CGColor,
               letterFill: CGColor, letterStroke: CGColor, seed: Double, name: String) {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.scaleBy(x: scale, y: scale)
    let center = CGPoint(x: C, y: C)

    // Radiating ink speed-lines fanning out behind the star (varied length, tapering).
    ctx.setStrokeColor(ink)
    let rays = 32
    for i in 0..<rays {
        let a = Double(i) / Double(rays) * 2 * .pi + seed
        let r0 = 35.0 + (i % 2 == 0 ? 2.5 : 0.0)
        let r1 = 45.0 + Double((i * 7 + Int(seed * 9)) % 6)
        ctx.setLineWidth(i % 2 == 0 ? 2.3 : 1.2)
        ctx.move(to: CGPoint(x: center.x + CGFloat(cos(a) * r0), y: center.y + CGFloat(sin(a) * r0)))
        ctx.addLine(to: CGPoint(x: center.x + CGFloat(cos(a) * r1), y: center.y + CGFloat(sin(a) * r1)))
        ctx.strokePath()
    }

    // Spiky star: 12 points, alternating outer/inner radius, jittered by seed.
    let spikes = 12
    let star = CGMutablePath()
    for i in 0..<(spikes * 2) {
        let outer = i % 2 == 0
        let rr = (outer ? 39.0 : 19.0) + sin(Double(i) * 1.7 + seed * 6) * 2.0
        let a = Double(i) / Double(spikes * 2) * 2 * .pi - .pi / 2 + seed * 0.3
        let p = CGPoint(x: center.x + CGFloat(cos(a) * rr), y: center.y + CGFloat(sin(a) * rr))
        if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
    }
    star.closeSubpath()

    // Thick black outline, then a radial fill (inner → outer colour).
    ctx.addPath(star); ctx.setLineJoin(.round); ctx.setLineWidth(6.0); ctx.setStrokeColor(ink); ctx.strokePath()
    ctx.saveGState(); ctx.addPath(star); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [starInner, starOuter] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(grad, startCenter: center, startRadius: 1, endCenter: center, endRadius: 40, options: [])
    // Ben-Day halftone speckle, denser toward the rim (printed-shading tell), kept subtle.
    for gx in stride(from: 8.0, through: 88.0, by: 4.6) {
        for gy in stride(from: 8.0, through: 88.0, by: 4.6) {
            let dx = gx - C, dy = gy - C
            let dr = (dx * dx + dy * dy).squareRoot()
            let cov = min(1.0, max(0.0, (dr - 18.0) / 22.0))     // none in the centre, more outward
            if cov > 0.08 {
                let rad = 0.7 + cov * 0.7
                ctx.setFillColor(rgb(0.08, 0.06, 0.05, 0.16 * cov))
                ctx.fillEllipse(in: CGRect(x: gx - rad, y: gy - rad, width: rad * 2, height: rad * 2))
            }
        }
    }
    ctx.restoreGState()

    // Comic lettering — chunky condensed, slightly slanted, with a keyline + a hard offset ink
    // shadow. Colours live on the attributed string (a negative strokeWidth fills AND strokes); the
    // context's fill colour is ignored by CoreText, which is why the letters drew black before.
    let size: CGFloat = word.count >= 4 ? 25.0 : 30.0
    let font = CTFontCreateWithName("HelveticaNeue-CondensedBlack" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: letterFill) ?? .white,
        .strokeColor: NSColor(cgColor: letterStroke) ?? .black,
        .strokeWidth: -6.0,                                                              // negative → fill + keyline (% of size)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: attrs))
    let b = CTLineGetImageBounds(line, ctx)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 2.0, height: -2.0), blur: 0, color: ink)        // hard comic shadow
    ctx.translateBy(x: center.x, y: center.y - 1.0)
    ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: -0.13, d: 1, tx: 0, ty: 0))         // comic slant
    ctx.textPosition = CGPoint(x: -b.width / 2 - b.minX, y: -b.height / 2 - b.minY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    if let img = ctx.makeImage() {
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)@2x.png"))
            print("wrote \(name)@2x.png")
        }
    }
}

// POP — red star, white letters. BANG — gold star, deep-red letters. POW — blue star, gold letters.
drawBurst("POP", starInner: rgb(1.0, 0.93, 0.55), starOuter: rgb(0.92, 0.20, 0.16),
          letterFill: rgb(0.97, 0.96, 0.92), letterStroke: rgb(0.08, 0.06, 0.05), seed: 0.06, name: "pop-sprite")
drawBurst("BANG", starInner: rgb(1.0, 0.97, 0.86), starOuter: rgb(0.97, 0.72, 0.12),
          letterFill: rgb(0.90, 0.20, 0.12), letterStroke: rgb(1.0, 0.97, 0.9), seed: 0.42, name: "bang-sprite")
drawBurst("POW", starInner: rgb(1.0, 0.99, 0.92), starOuter: rgb(0.20, 0.55, 0.90),
          letterFill: rgb(0.98, 0.80, 0.18), letterStroke: rgb(0.08, 0.06, 0.05), seed: 0.78, name: "pow-sprite")
