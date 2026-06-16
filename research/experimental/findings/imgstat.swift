// imgstat: read a PNG and print average color + a coarse color grid, so a
// headless agent can "see" a screenshot. Optional crop in pixel coords.
//
// Build: swiftc -O imgstat.swift -o imgstat
// Use:   ./imgstat <png> [x y w h] [gridCols gridRows]
import Foundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 2, let img = NSImage(contentsOfFile: args[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot load image\n".data(using: .utf8)!); exit(1)
}
let W = cg.width, H = cg.height
var cropX = 0, cropY = 0, cropW = W, cropH = H
if args.count >= 6 { cropX = Int(args[2])!; cropY = Int(args[3])!; cropW = Int(args[4])!; cropH = Int(args[5])! }
var cols = 10, rows = 7
if args.count >= 8 { cols = Int(args[6])!; rows = Int(args[7])! }
cropX = max(0, min(cropX, W-1)); cropY = max(0, min(cropY, H-1))
cropW = max(1, min(cropW, W-cropX)); cropH = max(1, min(cropH, H-cropY))

let bpp = 4, bpr = W*bpp
var buf = [UInt8](repeating: 0, count: H*bpr)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

func avg(_ x0:Int,_ y0:Int,_ w:Int,_ h:Int) -> (Int,Int,Int) {
    var r=0,g=0,b=0,n=0
    let step = max(1, (w*h)/4000)
    var i = 0
    for yy in stride(from:y0, to:min(y0+h,H), by:1) {
        for xx in stride(from:x0, to:min(x0+w,W), by:1) {
            i += 1; if i % step != 0 { continue }
            let o = yy*bpr + xx*bpp
            r += Int(buf[o]); g += Int(buf[o+1]); b += Int(buf[o+2]); n += 1
        }
    }
    if n==0 { return (0,0,0) }
    return (r/n, g/n, b/n)
}
let (ar,ag,ab) = avg(cropX,cropY,cropW,cropH)
print("image \(W)x\(H)  crop=(\(cropX),\(cropY),\(cropW),\(cropH))")
print(String(format:"AVG RGB = (%3d,%3d,%3d)  #%02X%02X%02X", ar,ag,ab,ar,ag,ab))
print("color grid (\(cols)x\(rows)), each cell = avg hex:")
let cw = cropW/cols, ch = cropH/rows
for ry in 0..<rows {
    var line = ""
    for rx in 0..<cols {
        let (r,g,b) = avg(cropX+rx*cw, cropY+ry*ch, cw, ch)
        line += String(format:"%02X%02X%02X ", r,g,b)
    }
    print(line)
}
