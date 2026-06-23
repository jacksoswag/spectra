#!/usr/bin/env swift
// Generates the ornate CORNER flourish for fx_chrome_spriteBorder (MAOE §12, Noir). Each element is
// drawn as a WHITE core over a wider BLACK outline — a black/white double outline — so the ornament
// stays legible on both light and dark backgrounds. RGB carries the two tones; the shader composites
// the sprite's own (premultiplied) colour rather than recolouring a single ink. One top-left corner
// is authored; the shader mirrors it into the other three.
// Run: swift Scripts/gen_border_sprites.swift
import AppKit
import CoreGraphics

let outDir = "Resources/BorderSprites"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let ptSize = 120.0, scale = 2.0          // 240 px source
let px = Int(ptSize * scale)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
ctx.scaleBy(x: scale, y: scale)
// Source art is top-left in image space; the shader samples uv (0,0) at the window corner. The
// CGContext origin is bottom-left, so flip Y once so "the corner" is at the top-left of the art.
ctx.translateBy(x: 0, y: ptSize); ctx.scaleBy(x: 1, y: -1)
ctx.setLineCap(.round); ctx.setLineJoin(.round)

let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let OUT = 1.2          // black outline extra half-width (pt) on each side of the white core
let S = ptSize

// Stroke a path as a white core over a wider black outline → a black/white double-outlined line.
func strokeBW(_ w: Double, _ build: () -> Void) {
    ctx.setStrokeColor(black); ctx.setLineWidth(w + 2 * OUT); build(); ctx.strokePath()
    ctx.setStrokeColor(white); ctx.setLineWidth(w);          build(); ctx.strokePath()
}
// Fill a path white, then ring it with a black outline → a white shape with a black edge.
func fillBW(_ rim: Double = 2 * OUT, _ build: () -> Void) {
    ctx.setFillColor(white);   build(); ctx.fillPath()
    ctx.setStrokeColor(black); ctx.setLineWidth(rim); build(); ctx.strokePath()
}

// 1. Double L-rule hugging the two edges that meet at the corner. The OUTER rule sits at the very
//    edge (inset ~1.6) so it lines up with the shader's solid edge rule; the inner rule is a Deco
//    second line. These run most of the way down each edge so the corner reads as continuous frame.
func lrulePath(_ inset: Double, _ len: Double) {
    ctx.move(to: CGPoint(x: inset, y: len)); ctx.addLine(to: CGPoint(x: inset, y: inset)); ctx.addLine(to: CGPoint(x: len, y: inset))
}
strokeBW(2.0) { lrulePath(1.6, S * 0.96) }        // outer rule — meets the shader edge rule
strokeBW(1.1) { lrulePath(6.5, S * 0.80) }        // inner Deco rule

// 2. A quarter-round node where the two rules turn the corner.
strokeBW(2.0) {
    let p = CGMutablePath()
    p.addArc(center: CGPoint(x: 1.6, y: 1.6), radius: 7.0, startAngle: 0, endAngle: .pi / 2, clockwise: false)
    ctx.addPath(p)
}

// 3. A quarter-fan sunburst springing diagonally from the corner node (the Deco signature).
let origin = CGPoint(x: 9, y: 9)
let rays = 8
for i in 0...rays {
    let a = (Double(i) / Double(rays)) * (.pi / 2)
    let len = 36.0
    strokeBW(i % 2 == 0 ? 2.2 : 1.1) {
        ctx.move(to: CGPoint(x: origin.x + cos(a) * 11.0, y: origin.y + sin(a) * 11.0))
        ctx.addLine(to: CGPoint(x: origin.x + cos(a) * len, y: origin.y + sin(a) * len))
    }
}

// 4. Two concentric quarter-arcs banding across the fan.
for (k, r) in [40.0, 47.0].enumerated() {
    strokeBW(k == 0 ? 2.0 : 1.1) {
        let arc = CGMutablePath()
        arc.addArc(center: origin, radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        ctx.addPath(arc)
    }
}

// 5. A pair of symmetric leaf accents on the diagonal, framing the fan.
func leafPath(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ tip: CGPoint, _ back: CGPoint) {
    let p = CGMutablePath()
    p.move(to: a); p.addCurve(to: tip, control1: c1, control2: c2)
    p.addCurve(to: a, control1: back, control2: a)
    ctx.addPath(p)
}
fillBW { leafPath(CGPoint(x: 30, y: 16), CGPoint(x: 44, y: 12), CGPoint(x: 56, y: 16), CGPoint(x: 64, y: 12), CGPoint(x: 48, y: 22)) }
fillBW { leafPath(CGPoint(x: 16, y: 30), CGPoint(x: 12, y: 44), CGPoint(x: 16, y: 56), CGPoint(x: 12, y: 64), CGPoint(x: 22, y: 48)) }

// 6. A small stepped lozenge accent on the inner diagonal.
let lc = CGPoint(x: 56, y: 56)
strokeBW(1.4) {
    let loz = CGMutablePath()
    loz.move(to: CGPoint(x: lc.x, y: lc.y - 6)); loz.addLine(to: CGPoint(x: lc.x + 6, y: lc.y))
    loz.addLine(to: CGPoint(x: lc.x, y: lc.y + 6)); loz.addLine(to: CGPoint(x: lc.x - 6, y: lc.y)); loz.closeSubpath()
    ctx.addPath(loz)
}
fillBW(1.4) {
    let p = CGMutablePath(); p.addEllipse(in: CGRect(x: lc.x - 2.4, y: lc.y - 2.4, width: 4.8, height: 4.8)); ctx.addPath(p)
}

if let img = ctx.makeImage() {
    let rep = NSBitmapImageRep(cgImage: img)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/ornate-corner@2x.png"))
        print("wrote ornate-corner@2x.png")
    }
}
