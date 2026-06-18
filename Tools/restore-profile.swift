// One-shot recovery: reset the main display to its FACTORY color profile, discarding
// any custom profile assignment (including a contaminated swapped one). Safe: at worst
// it reverts a display from a custom calibration to the default profile, which the user
// can reselect in System Settings > Displays > Color.
import Foundation
import CoreGraphics
import ApplicationServices

let displayID = CGMainDisplayID()
guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { exit(1) }
let deviceClass = kColorSyncDisplayDeviceClass.takeUnretainedValue()

// Passing nil clears the custom profile override -> factory/default profile.
let ok = ColorSyncDeviceSetCustomProfiles(deviceClass, uuid, nil)
print("reset to factory profile: \(ok)")
CGDisplayRestoreColorSyncSettings()
