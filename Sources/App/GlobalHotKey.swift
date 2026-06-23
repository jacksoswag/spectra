import AppKit
import Carbon.HIToolbox

/// A process-wide hotkey registered through Carbon's `RegisterEventHotKey`, so it
/// fires even when Spectra is not the frontmost app and even when its windows are
/// hidden behind the overlay. Spectra uses it as a panic switch: when "Cover menu
/// bar & Dock" raises the overlay over the system chrome, the menu-bar item is no
/// longer visible, so this is the guaranteed way to turn the overlay off.
///
/// Carbon hotkeys need no Accessibility permission (unlike a `CGEventTap`). The
/// handler is installed on the application event target, which is serviced on the
/// main run loop; the fire callback is still hopped to the main queue defensively
/// before touching app state.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: () -> Void

    /// `keyCode` is a Carbon virtual key code (e.g. `kVK_ANSI_S`); `modifiers` is a
    /// Carbon modifier mask (e.g. `cmdKey | optionKey | controlKey`). `id` distinguishes
    /// this app's hotkeys from each other (each registration needs a unique id). Returns
    /// nil if the OS refuses the registration (e.g. the chord is already taken).
    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, onFire: @escaping () -> Void) {
        self.onFire = onFire

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { instance.onFire() }
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef)
        guard installStatus == noErr else { return nil }

        // 'SPKY' — a fourCC signature distinguishing this app's hotkeys.
        let hotKeyID = EventHotKeyID(signature: OSType(0x53504B59), id: id)
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr, hotKeyRef != nil else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// ⌃⌥⌘S — Spectra's panic chord. A distinct combo (not the in-app ⌘⇧E toggle,
    /// which a global registration would steal from every other app and double-fire
    /// in-app). Keeps the Carbon key/modifier constants out of the call site.
    static func panicSwitch(onFire: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            onFire: onFire)
    }

    /// Human-readable label for the panic chord, for UI hints.
    static let panicSwitchLabel = "⌃⌥⌘S"

    /// ⌥⌘P — a global pause/unpause (Start/Stop) chord. Works from any app, unlike the
    /// in-app ⌘⇧E toggle. Uses a distinct hotkey `id` so it doesn't collide with the
    /// panic switch's registration.
    static func toggle(onFire: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(optionKey | cmdKey),
            id: 2,
            onFire: onFire)
    }

    /// Human-readable label for the pause/unpause chord, for UI hints.
    static let toggleLabel = "⌥⌘P"

    /// ⌥⌘W — cycle to the next world (MAOE §16.3 hotkey world-switcher).
    static func cycleWorld(onFire: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(optionKey | cmdKey), id: 3, onFire: onFire)
    }

    /// ⌥⌘F — punch the focused window out of the effect / restore it (MAOE §16.3 filter-window).
    static func filterWindow(onFire: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | cmdKey), id: 4, onFire: onFire)
    }

    /// ⌥⌘C — write the styled desktop frame to a PNG (MAOE §15.4 one-press capture).
    static func captureFrame(onFire: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey | cmdKey), id: 5, onFire: onFire)
    }
}
