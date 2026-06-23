#!/usr/bin/env swift
// Generates the bespoke @2x cursor sprites + cursor-hotspots.json (MAOE §6) as detailed
// CoreGraphics vector art: a Noir magnifying glass, a retro 8-bit arrow, a Frutiger glossy
// arrow, a Reading typewriter key, and a Fuji fountain-pen nib. Transparent, with hotspots at
// each object's natural point. Run: swift Scripts/gen_cursor_sprites.swift
import AppKit
import CoreGraphics

let outDir = "Resources/CursorSprites"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let ptSize = 26.0, scale = 2.0
let px = Int(ptSize * scale)

func makeContext(antialias: Bool = true) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.setShouldAntialias(antialias)
    ctx.translateBy(x: 0, y: CGFloat(px))   // top-left origin to match the cursor UV space
    ctx.scaleBy(x: scale, y: -scale)
    return ctx
}

func writePNG(_ ctx: CGContext, _ name: String) {
    guard let img = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)@2x.png"))
    print("wrote \(name)@2x.png")
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

// 1. Noir — a STYLIZED Art-Deco pointer in stark 1930s B&W: the arrow silhouette is split two-tone,
//    a cream "paper" upper-left against an inked lower-right, with a bold ink keyline and a soft drop
//    shadow. Clearly a pointer (not a magnifier, not a plain system arrow), and distinctly noir.
//    Hotspot at the tip; the cream/ink palette matches its own I-beam/hand variants below.
do {
    let c = makeContext()
    c.setLineCap(.round); c.setLineJoin(.round)
    // A slightly elongated, more elegant arrow than the shared system pointer (its own stylized shape).
    let aPts: [CGPoint] = [CGPoint(x: 1, y: 1), CGPoint(x: 1.6, y: 17.5), CGPoint(x: 5.2, y: 13.2),
                           CGPoint(x: 8.2, y: 20.0), CGPoint(x: 10.7, y: 18.8), CGPoint(x: 7.7, y: 12.4),
                           CGPoint(x: 12.8, y: 12.4)]
    let arrow = CGMutablePath(); arrow.move(to: aPts[0]); for q in aPts.dropFirst() { arrow.addLine(to: q) }; arrow.closeSubpath()
    let ink = rgb(0.05, 0.05, 0.06)
    // SOLID cream fill so it stays visible on the dark noir desktop; a bold ink keyline carries it on
    // light frames. Stylized with an inked Art-Deco chevron echoing the tip (a "double point" that
    // reads as a pointer + a 1930s deco flourish) and a small ink diamond echoing the border's beads.
    c.setShadow(offset: CGSize(width: 0.6, height: -0.9), blur: 1.8, color: rgb(0, 0, 0, 0.6))
    c.addPath(arrow); c.setFillColor(rgb(0.95, 0.95, 0.93)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(arrow); c.setStrokeColor(ink); c.setLineWidth(1.8); c.strokePath()        // bold ink keyline
    c.move(to: CGPoint(x: 2.3, y: 6.4)); c.addLine(to: CGPoint(x: 4.7, y: 3.9)); c.addLine(to: CGPoint(x: 7.1, y: 6.6))
    c.setStrokeColor(ink); c.setLineWidth(1.4); c.strokePath()                          // deco chevron at the tip
    let d = CGPoint(x: 6.5, y: 15.2), dia = CGMutablePath()
    dia.move(to: CGPoint(x: d.x, y: d.y - 1.5)); dia.addLine(to: CGPoint(x: d.x + 1.5, y: d.y))
    dia.addLine(to: CGPoint(x: d.x, y: d.y + 1.5)); dia.addLine(to: CGPoint(x: d.x - 1.5, y: d.y)); dia.closeSubpath()
    c.addPath(dia); c.setFillColor(ink); c.fillPath()                                   // deco bead at the tail
    writePNG(c, "noir-object")
}

// 2. CRT / VHS — the classic 90s Windows pointer: a white arrow with a black keyline. Hotspot tip.
do {
    let c = makeContext()
    let pts: [CGPoint] = [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 15.5), CGPoint(x: 4.6, y: 12.2),
                          CGPoint(x: 7.3, y: 18.4), CGPoint(x: 9.6, y: 17.4), CGPoint(x: 6.9, y: 11.5),
                          CGPoint(x: 11.6, y: 11.5)]
    let p = CGMutablePath(); p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }; p.closeSubpath()
    c.addPath(p); c.setFillColor(rgb(1, 1, 1)); c.fillPath()                       // white fill
    c.addPath(p); c.setStrokeColor(rgb(0, 0, 0)); c.setLineWidth(1.2); c.setLineJoin(.miter); c.strokePath()  // black keyline
    writePNG(c, "retro-8090")
}

// 3. Frutiger Aero — a glossy aqua arrow with a gel highlight + soft shadow. Hotspot top-left.
do {
    let c = makeContext()
    let arrow: [CGPoint] = [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 17), CGPoint(x: 5, y: 13),
                            CGPoint(x: 8, y: 20), CGPoint(x: 10.5, y: 19), CGPoint(x: 7.5, y: 12.5),
                            CGPoint(x: 12.5, y: 12.5)]
    func path() -> CGPath { let p = CGMutablePath(); p.move(to: arrow[0]); for q in arrow.dropFirst() { p.addLine(to: q) }; p.closeSubpath(); return p }
    c.setShadow(offset: CGSize(width: 0, height: -1.2), blur: 2.5, color: rgb(0, 0.1, 0.2, 0.5))
    c.addPath(path()); c.setFillColor(rgb(0.2, 0.55, 0.95)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    // vertical aqua gradient clipped to the arrow.
    c.saveGState(); c.addPath(path()); c.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(0.6, 0.9, 1.0), rgb(0.1, 0.45, 0.9)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1), end: CGPoint(x: 0, y: 20), options: [])
    // gel highlight on the upper-left half.
    c.setFillColor(rgb(1, 1, 1, 0.55))
    c.move(to: CGPoint(x: 1.6, y: 2)); c.addLine(to: CGPoint(x: 1.6, y: 9)); c.addLine(to: CGPoint(x: 5, y: 6)); c.closePath(); c.fillPath()
    c.restoreGState()
    c.addPath(path()); c.setStrokeColor(rgb(1, 1, 1, 0.9)); c.setLineWidth(0.9); c.strokePath()
    writePNG(c, "aero-2000s")
}

// 4. Reading — a small open book (cream pages, dark spine + faint text lines), not a letter key.
//    Hotspot near its centre.
do {
    let c = makeContext()
    func page(_ m: Double) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 13, y: 6.5))
        p.addLine(to: CGPoint(x: 13 + m * 9, y: 8.5))
        p.addLine(to: CGPoint(x: 13 + m * 9, y: 17.0))
        p.addLine(to: CGPoint(x: 13, y: 16.0))
        p.closeSubpath(); return p
    }
    c.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: rgb(0, 0, 0, 0.45))
    c.addPath(page(-1)); c.addPath(page(1)); c.setFillColor(rgb(0.94, 0.91, 0.83)); c.fillPath()   // cream pages
    c.setShadow(offset: .zero, blur: 0, color: nil)
    // outline + spine.
    c.setLineJoin(.round); c.setLineCap(.round)
    c.addPath(page(-1)); c.addPath(page(1)); c.setStrokeColor(rgb(0.16, 0.14, 0.12)); c.setLineWidth(1.1); c.strokePath()
    c.move(to: CGPoint(x: 13, y: 6.5)); c.addLine(to: CGPoint(x: 13, y: 16.0)); c.setLineWidth(1.4); c.strokePath()
    // faint text lines on each page.
    c.setStrokeColor(rgb(0.16, 0.14, 0.12, 0.45)); c.setLineWidth(0.5)
    for dy in [10.5, 12.6, 14.7] {
        c.move(to: CGPoint(x: 5.5, y: dy)); c.addLine(to: CGPoint(x: 11.2, y: dy))
        c.move(to: CGPoint(x: 14.8, y: dy)); c.addLine(to: CGPoint(x: 20.5, y: dy))
    }
    c.strokePath()
    writePNG(c, "typewriter")
}

// 5. Fuji — a fountain-pen nib (ink blue, slit + vent hole + tines). Hotspot at the nib tip.
do {
    let c = makeContext()
    // nib outline: a pointed teardrop, tip at top-left.
    let nib = CGMutablePath()
    nib.move(to: CGPoint(x: 2, y: 2))                       // tip (hotspot)
    nib.addCurve(to: CGPoint(x: 14, y: 14), control1: CGPoint(x: 7, y: 4), control2: CGPoint(x: 12, y: 9))
    nib.addCurve(to: CGPoint(x: 2, y: 2), control1: CGPoint(x: 9, y: 12), control2: CGPoint(x: 4, y: 7))
    nib.closeSubpath()
    c.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: rgb(0, 0, 0.1, 0.45))
    c.addPath(nib); c.setFillColor(rgb(0.14, 0.2, 0.42)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.saveGState(); c.addPath(nib); c.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(0.4, 0.5, 0.8), rgb(0.1, 0.15, 0.35)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 2, y: 2), end: CGPoint(x: 12, y: 12), options: [])
    c.restoreGState()
    // centre slit + vent hole + rim.
    c.setStrokeColor(rgb(0.85, 0.88, 0.95, 0.9)); c.setLineWidth(0.7)
    c.move(to: CGPoint(x: 2.6, y: 2.6)); c.addLine(to: CGPoint(x: 9, y: 9)); c.strokePath()
    c.setFillColor(rgb(0.85, 0.88, 0.95)); c.fillEllipse(in: CGRect(x: 8.2, y: 8.2, width: 2, height: 2))
    c.addPath(nib); c.setStrokeColor(rgb(0.8, 0.84, 0.95, 0.8)); c.setLineWidth(0.6); c.strokePath()
    writePNG(c, "serif")
}

// A shared pointer-arrow outline (tip at the top-left), reused by the world cursors below.
func arrowPath() -> CGPath {
    let pts: [CGPoint] = [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 16.5), CGPoint(x: 5, y: 12.5),
                          CGPoint(x: 8, y: 19.5), CGPoint(x: 10.5, y: 18.3), CGPoint(x: 7.6, y: 11.8),
                          CGPoint(x: 12.5, y: 11.8)]
    let p = CGMutablePath(); p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }; p.closeSubpath()
    return p
}

// 6. Matrix — a phosphor-green pixel arrow (antialias off → crisp stair-stepped pixel edges).
do {
    let c = makeContext(antialias: false)
    c.addPath(arrowPath()); c.setFillColor(rgb(0.16, 0.92, 0.34)); c.fillPath()       // bright phosphor
    c.addPath(arrowPath()); c.setStrokeColor(rgb(0.0, 0.16, 0.05)); c.setLineWidth(1.4); c.strokePath()  // dark key-line
    writePNG(c, "matrix-pixel")
}

// 7. Cyberpunk — a brushed-steel industrial pointer with a thin violet edge (premium, not RGB).
do {
    let c = makeContext()
    c.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: rgb(0, 0, 0, 0.5))
    c.addPath(arrowPath()); c.setFillColor(rgb(0.30, 0.32, 0.40)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.saveGState(); c.addPath(arrowPath()); c.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgb(0.86, 0.88, 0.94), rgb(0.28, 0.30, 0.40)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1), end: CGPoint(x: 0, y: 20), options: [])
    c.restoreGState()
    c.addPath(arrowPath()); c.setStrokeColor(rgb(0.58, 0.32, 0.92, 0.9)); c.setLineWidth(0.9); c.strokePath()   // violet edge
    writePNG(c, "cyber-steel")
}

// 8. Night Light — a soft warm amber pointer with a gentle glow (low-glare, late-night).
do {
    let c = makeContext()
    c.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: rgb(0.5, 0.3, 0.1, 0.5))
    c.addPath(arrowPath()); c.setFillColor(rgb(1.0, 0.82, 0.52)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(arrowPath()); c.setStrokeColor(rgb(0.6, 0.42, 0.22)); c.setLineWidth(0.9); c.strokePath()
    writePNG(c, "night-warm")
}

// 9. Comic Book — a bold pop-art arrow: bright flat fill, a thick black ink keyline, and a hard
//    offset ink shadow. Hotspot at the tip.
do {
    let c = makeContext()
    c.setShadow(offset: CGSize(width: 1.0, height: -1.0), blur: 0, color: rgb(0.05, 0.05, 0.05))
    c.addPath(arrowPath()); c.setFillColor(rgb(1.0, 0.85, 0.12)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(arrowPath()); c.setStrokeColor(rgb(0.05, 0.05, 0.05)); c.setLineWidth(2.2); c.setLineJoin(.round); c.strokePath()
    writePNG(c, "comic-ink")
}

// 10. Pencil Sketch — a graphite pencil pointing up-left (the sharpened point is the hotspot).
do {
    let c = makeContext()
    let tip = CGPoint(x: 1.5, y: 1.5)
    let ax = (x: 0.7071, y: 0.7071), pp = (x: -0.7071, y: 0.7071)
    func P(_ a: Double, _ pr: Double) -> CGPoint { CGPoint(x: tip.x + ax.x * a + pp.x * pr, y: tip.y + ax.y * a + pp.y * pr) }
    func seg(_ a0: Double, _ a1: Double, _ w: Double) -> CGPath {
        let p = CGMutablePath(); p.move(to: P(a0, -w)); p.addLine(to: P(a1, -w)); p.addLine(to: P(a1, w)); p.addLine(to: P(a0, w)); p.closeSubpath(); return p
    }
    c.setLineJoin(.round)
    let point = CGMutablePath(); point.move(to: tip); point.addLine(to: P(3, 1.0)); point.addLine(to: P(3, -1.0)); point.closeSubpath()
    c.addPath(point); c.setFillColor(rgb(0.18, 0.18, 0.20)); c.fillPath()                       // graphite point
    let wood = CGMutablePath(); wood.move(to: P(3, -1.0)); wood.addLine(to: P(4.6, -1.8)); wood.addLine(to: P(4.6, 1.8)); wood.addLine(to: P(3, 1.0)); wood.closeSubpath()
    c.addPath(wood); c.setFillColor(rgb(0.82, 0.68, 0.5)); c.fillPath()                          // sharpened wood
    c.addPath(seg(4.6, 18.5, 1.8)); c.setFillColor(rgb(0.55, 0.55, 0.58)); c.fillPath()          // graphite-grey body
    c.addPath(seg(18.5, 20.0, 1.8)); c.setFillColor(rgb(0.72, 0.72, 0.74)); c.fillPath()         // ferrule
    c.addPath(seg(20.0, 21.6, 1.8)); c.setFillColor(rgb(0.9, 0.55, 0.55)); c.fillPath()          // eraser
    // sketchy silhouette outline.
    let sil = CGMutablePath()
    sil.move(to: tip); sil.addLine(to: P(3, -1.0)); sil.addLine(to: P(4.6, -1.8)); sil.addLine(to: P(21.6, -1.8))
    sil.addLine(to: P(21.6, 1.8)); sil.addLine(to: P(4.6, 1.8)); sil.addLine(to: P(3, 1.0)); sil.closeSubpath()
    c.addPath(sil); c.setStrokeColor(rgb(0.15, 0.15, 0.17)); c.setLineWidth(0.8); c.strokePath()
    writePNG(c, "pencil-tip")
}

// 11. Print Art — a pointer with CONCAVE pagoda-roof edges (ukiyo-e indigo, woodblock keyline).
//     The two long edges bow inward like a Japanese eave. Hotspot at the tip.
do {
    let c = makeContext()
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 1, y: 1))                                              // tip
    p.addQuadCurve(to: CGPoint(x: 1.7, y: 16.0), control: CGPoint(x: 3.6, y: 8.5))   // concave left eave
    p.addLine(to: CGPoint(x: 5.0, y: 12.0))
    p.addLine(to: CGPoint(x: 8.0, y: 19.0))
    p.addLine(to: CGPoint(x: 10.6, y: 17.9))
    p.addLine(to: CGPoint(x: 7.6, y: 11.4))
    p.addLine(to: CGPoint(x: 12.6, y: 11.4))
    p.addQuadCurve(to: CGPoint(x: 1, y: 1), control: CGPoint(x: 6.6, y: 5.6))        // concave top eave
    p.closeSubpath()
    c.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: rgb(0, 0, 0.05, 0.45))
    c.addPath(p); c.setFillColor(rgb(0.20, 0.26, 0.52)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(p); c.setStrokeColor(rgb(0.05, 0.07, 0.13)); c.setLineWidth(1.1); c.setLineJoin(.round); c.strokePath()
    writePNG(c, "print-roof")
}

// I-beam (text) + pointing-hand variants per world, in the world's palette. The sampler swaps to
// these when the live system cursor is a text caret or a link hand (MAOE §6); a missing variant
// falls back to the world's arrow.
struct CursorTheme { let name: String; let fill: CGColor; let stroke: CGColor; let pixel: Bool }
let themes: [CursorTheme] = [
    CursorTheme(name: "noir-object",  fill: rgb(0.95, 0.95, 0.93), stroke: rgb(0.05, 0.05, 0.06), pixel: false),
    CursorTheme(name: "retro-8090",   fill: rgb(1, 1, 1),          stroke: rgb(0, 0, 0),          pixel: false),
    CursorTheme(name: "aero-2000s",   fill: rgb(0.55, 0.82, 1.0),  stroke: rgb(0.10, 0.35, 0.70), pixel: false),
    CursorTheme(name: "typewriter",   fill: rgb(0.93, 0.90, 0.82), stroke: rgb(0.16, 0.14, 0.12), pixel: false),
    CursorTheme(name: "matrix-pixel", fill: rgb(0.18, 0.92, 0.34), stroke: rgb(0.00, 0.16, 0.05), pixel: true),
    CursorTheme(name: "cyber-steel",  fill: rgb(0.80, 0.82, 0.90), stroke: rgb(0.58, 0.32, 0.92), pixel: false),
    CursorTheme(name: "night-warm",   fill: rgb(1.00, 0.82, 0.52), stroke: rgb(0.60, 0.42, 0.22), pixel: false),
    CursorTheme(name: "comic-ink",    fill: rgb(1.00, 0.85, 0.12), stroke: rgb(0.05, 0.05, 0.05), pixel: false),
    CursorTheme(name: "pencil-tip",   fill: rgb(0.55, 0.55, 0.58), stroke: rgb(0.15, 0.15, 0.17), pixel: false),
    CursorTheme(name: "print-roof",   fill: rgb(0.20, 0.26, 0.52), stroke: rgb(0.05, 0.07, 0.13), pixel: false),
]

// A classic I-beam (vertical bar + serif caps), filled with a keyline expansion so it reads on any
// background. Hotspot at its centre.
func drawIBeam(_ t: CursorTheme) {
    let c = makeContext(antialias: !t.pixel)
    let cx = 13.0, top = 4.0, bot = 22.0
    func iShape(_ d: Double) -> CGPath {
        let p = CGMutablePath()
        p.addRect(CGRect(x: cx - 3.6 - d, y: top - d,       width: 7.2 + 2*d, height: 2.4 + 2*d))     // top cap
        p.addRect(CGRect(x: cx - 1.2 - d, y: top - d,       width: 2.4 + 2*d, height: (bot - top) + 2*d))  // stem
        p.addRect(CGRect(x: cx - 3.6 - d, y: bot - 2.4 - d, width: 7.2 + 2*d, height: 2.4 + 2*d))     // bottom cap
        return p
    }
    c.addPath(iShape(0.9)); c.setFillColor(t.stroke); c.fillPath()   // keyline (expanded)
    c.addPath(iShape(0.0)); c.setFillColor(t.fill); c.fillPath()     // fill
    writePNG(c, "\(t.name)-text")
}

// A pointing hand (index finger up over a fist), keyline + fill. Hotspot at the fingertip.
func drawHand(_ t: CursorTheme) {
    let c = makeContext(antialias: !t.pixel)
    func handShape(_ d: Double) -> CGPath {
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: 8.8 - d, y: 2 - d, width: 3.4 + 2*d, height: 9 + 2*d), cornerWidth: 1.7, cornerHeight: 1.7, transform: .identity)      // index finger
        p.addRoundedRect(in: CGRect(x: 6.5 - d, y: 9 - d, width: 10 + 2*d, height: 11 + 2*d), cornerWidth: 3, cornerHeight: 3, transform: .identity)          // palm
        p.addRoundedRect(in: CGRect(x: 4.8 - d, y: 11.5 - d, width: 3.5 + 2*d, height: 4.5 + 2*d), cornerWidth: 1.6, cornerHeight: 1.6, transform: .identity) // thumb
        return p
    }
    c.addPath(handShape(0.9)); c.setFillColor(t.stroke); c.fillPath()
    c.addPath(handShape(0.0)); c.setFillColor(t.fill); c.fillPath()
    writePNG(c, "\(t.name)-hand")
}

// Hotspots in points: each object's natural pointing/focus location.
var hotspots: [String: [String: Double]] = [
    "noir-object": ["x": 1, "y": 1],     // arrow tip
    "retro-8090": ["x": 1, "y": 1],      // arrow tip
    "aero-2000s": ["x": 1.5, "y": 1.5],  // arrow tip
    "typewriter": ["x": 13, "y": 13],    // key centre
    "serif": ["x": 2, "y": 2],           // nib tip
    "matrix-pixel": ["x": 1, "y": 1],    // arrow tip
    "cyber-steel": ["x": 1, "y": 1],     // arrow tip
    "night-warm": ["x": 1, "y": 1],      // arrow tip
    "comic-ink": ["x": 1, "y": 1],       // arrow tip
    "pencil-tip": ["x": 1.5, "y": 1.5],  // graphite point
    "print-roof": ["x": 1, "y": 1],      // tip
]
for t in themes {
    drawIBeam(t); drawHand(t)
    hotspots["\(t.name)-text"] = ["x": 13, "y": 13]    // caret centre
    hotspots["\(t.name)-hand"] = ["x": 10.5, "y": 2]   // fingertip
}
let json = try! JSONSerialization.data(withJSONObject: hotspots, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(outDir)/cursor-hotspots.json"))
print("wrote cursor-hotspots.json")
