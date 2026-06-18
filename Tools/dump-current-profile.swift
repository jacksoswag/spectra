// Dump the main display's CURRENT effective color profile to /tmp/spectra-current.icc
// (read-only — changes nothing) so we can inspect whether red/blue are swapped.
import Foundation
import CoreGraphics
import ApplicationServices

let displayID = CGMainDisplayID()
guard let cur = ColorSyncProfileCreateWithDisplayID(displayID)?.takeRetainedValue() else { exit(1) }
var err: Unmanaged<CFError>?
guard let data = ColorSyncProfileCopyData(cur, &err)?.takeRetainedValue() else { exit(1) }
try? (data as Data).write(to: URL(fileURLWithPath: "/tmp/spectra-current.icc"))
if let descU = ColorSyncProfileCopyDescriptionString(cur) {
    print("current profile: \(descU.takeRetainedValue() as String)")
}
