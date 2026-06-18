// Read-only: report the live gamma transfer table shape for ALL THREE channels per
// display, so a per-channel inversion on only green/blue (a hue shift) is visible.
import Foundation
import CoreGraphics

var count: UInt32 = 0
CGGetOnlineDisplayList(16, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)

func shape(_ a: [CGGammaValue], _ k: Int) -> String {
    let first = a[0], last = a[k-1]
    return last >= first ? "norm" : "INVERTED"
}

for id in ids {
    let cap = CGDisplayGammaTableCapacity(id)
    var r = [CGGammaValue](repeating: 0, count: Int(cap))
    var g = [CGGammaValue](repeating: 0, count: Int(cap))
    var b = [CGGammaValue](repeating: 0, count: Int(cap))
    var n: UInt32 = 0
    let err = CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &n)
    let k = Int(n)
    guard err == .success, k > 1 else { print("display \(id): can't read gamma"); continue }
    let main = (id == CGMainDisplayID()) ? " [main]" : ""
    print(String(format: "display %u%@:", id, main))
    print(String(format: "  R: first=%.3f last=%.3f -> %@", r[0], r[k-1], shape(r, k)))
    print(String(format: "  G: first=%.3f last=%.3f -> %@", g[0], g[k-1], shape(g, k)))
    print(String(format: "  B: first=%.3f last=%.3f -> %@", b[0], b[k-1], shape(b, k)))
}
