# Test 1 — Virtual-display compositor emulation (EMPIRICAL)

**Machine:** MacBook Air M3, macOS 26.5.1 (25F80), SIP off.
**Verdict: the load-bearing private capability WORKS and is buildable today.** The risky
parts that turn it into a real "compositor emulation" (display takeover + input
re-injection) were deliberately NOT automated overnight; see "Not done".

## What was run

`vd_create.m` — declares the private `CGVirtualDisplay{Descriptor,Settings,Mode}` interface,
creates a **headless secondary** 1920×1080@60 display (27-inch size trick, hiDPI=0), confirms
it registers, captures it, and tears it down on release. Never made main, never mirrored,
real panel untouched.

## Results (clean, repeatable)

```
[before] active displays = 1: 1(main)(builtin)
CGVirtualDisplay alloc = 0x96f0dcb60
applySettings -> YES
VD displayID = 8  isMain=0 isBuiltin=0 isOnline=1
[after applySettings] active displays = 2: 1(main)(builtin) 8
... 8s alive ...
releasing VD...
[after release] active displays = 1: 1(main)(builtin)
```

- **VD creation succeeds with `applySettings:` alone.** No SkyLight call (`SLSConfigureDisplayEnabled`)
  was needed for it to appear (the conditional SLS fallback never fired). Matches KhaosT/FluffyDisplay.
- **WindowServer composites a full desktop onto the VD.** `screencapture` of the VD produced a
  **1920×1080** image (exactly the requested mode, 1x because hiDPI=0) containing a real desktop
  wallpaper gradient — proof the system treats it as a genuine monitor and renders into it.
- **Clean teardown.** Releasing the object returned the display list to 1. No residue, no crash,
  desktop reverted.
- **AppKit gotcha:** `CGGetActiveDisplayList` saw the VD immediately, but `NSScreen.screens`
  stayed at 1 within the process (AppKit's screen cache did not refresh for an Accessory app in
  the short window). Use the CoreGraphics display list as the source of truth, or listen for
  `CGDisplayReconfigurationCallback` / `NSApplication.didChangeScreenParametersNotification`.
- The 27-inch `sizeInMillimeters` (597×336) + `maxPixelsWide/High` worked first try; no 4K
  rejection (and the M4/M5 4K HiDPI regression does not apply to this M3).

## What this proves for Architecture C (hybrid compositor emulation)

The data path `CGVirtualDisplay (private) → WindowServer composites desktop → capture →
[Metal shader] → present` is real and constructible on the current OS. Spectra already owns
the `capture → Metal → present` half (its whole engine), so bolting it onto a VD source is
a small addition. The VD creation is private CoreGraphics but stable and widely shipped
(BetterDisplay, FluffyDisplay, DisplayLink, Lumen).

## Not done (deliberately — unsafe for an unattended run)

These are exactly the parts that make Architecture C a *replacement* compositor, and exactly
the parts that are fragile / disruptive:

1. **Making the VD the main display + suppressing the real panel.** This relocates the entire
   desktop (menu bar, Dock, all windows) onto the invisible VD. A bug, crash, or my process
   exiting would strand the desktop on a display with no output. Too risky while the user sleeps.
2. **Input re-injection.** A headless VD has no HID association; a real build must capture HID
   via `CGEventTap`, remap real-panel coords to VD coords, and re-post via
   `CGWarpMouseCursorPosition` + `CGEventPost` (needs Accessibility TCC). Not exercised:
   it would move the sleeping user's cursor and needs a permission grant. This is also the
   source of the "underwater input" latency that makes C a bad product trade.

## Conclusion

Architecture C is **Experimental / Research-grade, but the foundation is proven on this exact
machine.** The VD half is solid. The reasons it stays research-grade are unchanged: the
display-takeover is a reliability hazard (version-fragile private APIs, stranding risk on
crash) and the input round-trip stacks a second latency hit on top of the capture round-trip.
For Spectra's actual goal (whole-desktop shading), the plain capture→Metal→overlay engine it
already has avoids ALL of this and is the right choice; the VD only buys "underlying desktop
hidden + total z-order," paid for with input lag.
