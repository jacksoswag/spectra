# Spectra experimental research: compositor-shader paths 1-4

Live, on-machine tests of the four experimental approaches to system-wide / per-window GPU
shaders beyond Spectra's shipping ScreenCaptureKit→Metal→overlay engine. Start with
[SUMMARY.md](SUMMARY.md). Each numbered folder has runnable source and a `FINDINGS.md`.

All tests were run on macOS 26.5.1 / Apple M3 with SIP disabled and `-arm64e_preview_abi`.
They are read-only or self-contained; none modify the system, and the deliberately-skipped
steps (display takeover, input reinjection, live Dock/WindowServer injection) are documented
in the per-test findings.

## Rebuild / rerun

```sh
# 1. Virtual display (creates a headless secondary display for 8s, then removes it)
cd 01_virtual_display
clang -fobjc-arc -framework Cocoa -framework CoreGraphics vd_create.m -o vd_create && ./vd_create 8

# 2. CGS window filter (pops a test-card window; pass a filter name)
cd 02_cgs_window_filter
clang -fobjc-arc -framework Cocoa -framework QuartzCore -framework CoreImage cgsfilter.m -o cgsfilter
./cgsfilter CIColorInvert 1 opaque      # or: CIPixellate / blurradius / custom / none

# 3. Per-app injection (self-contained target + dylib)
cd 03_per_app_injection
clang -fobjc-arc -framework Foundation -framework QuartzCore -framework Metal target.m -o target
clang -fobjc-arc -dynamiclib -framework Foundation -framework QuartzCore inject.m -o inject.dylib
DYLD_INSERT_LIBRARIES="$PWD/inject.dylib" ./target

# 4. WindowServer injection probe (read-only)
cd 04_windowserver_injection
clang -o probe probe.c && codesign -s - -f --entitlements debugger.entitlements probe && ./probe

# visual verification helper (reads a PNG, prints avg color + grid)
cd findings && swiftc -O imgstat.swift -o imgstat
```

## Verification method

Screenshots are captured non-interactively with `/usr/sbin/screencapture` (the controlling
`com.anthropic.claude-code` process holds Screen Recording TCC) and read with
`findings/imgstat`, since computer-use screenshots need an interactive approval dialog and
exclude ungranted apps at the compositor level.
