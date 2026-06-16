# Experimental paths 1-4: empirical results on this machine

Tested live on **MacBook Air M3 (Mac15,12), macOS 26.5.1 (25F80), SIP disabled,
Authenticated-Root disabled, boot-args `-arm64e_preview_abi`** (no `amfi_get_out_of_my_way`).
Every result below was produced by compiling and running code on this machine, not from
literature. Per-test detail and source code live in each numbered subfolder; helper in `findings/`.

## One-line verdicts

| # | Path | Result on this machine |
|---|------|------------------------|
| 1 | Virtual-display compositor emulation | **Foundation works.** Private `CGVirtualDisplay` creates a real headless secondary display; WindowServer composites a full desktop onto it; capturable at VD resolution; clean teardown. The takeover + input-reinjection parts that make it a true emulator are the fragile/risky bits and were not automated. **Experimental.** |
| 2 | CGS per-window CoreImage filter | **Dead.** `CGSNewCIFilterByName` returns `kCGErrorNotImplemented` for all 24 filter names except `CIColorInvert`, and `CIColorInvert` is a silent no-op (pixel-identical capture). Only `CGSSetWindowBackgroundBlurRadius` still works (verified: real edge-smear). **Not feasible for shaders.** |
| 3 | Per-app injection (yabai pattern) | **Works**, including into Apple platform binaries (`/bin/echo`, `/usr/bin/true`) with an arm64e dylib, no `amfi_get_out_of_my_way` needed. Hooked `-[CAMetalLayer nextDrawable]` live. The gate is library-validation (`0x2000`), which Dock/echo lack and WindowServer has. **Experimental, per-app only.** |
| 4 | WindowServer injection | **Not feasible.** `task_for_pid(WindowServer)` denied even with a debugger entitlement on SIP-off; `vmmap` denied; library-validation blocks any foreign dylib; can't relaunch without logging out. Meanwhile `task_for_pid(Dock)` succeeds. **Confirmed impossible.** |

## The two facts that decide everything

1. **WindowServer is walled off by `task_for_pid` denial AND library-validation (`0x2000`).**
   Dock is not (`task_for_pid` succeeds, flags `0x0`). This is why every "inject into the
   compositor" idea fails while "inject into Dock" (yabai) succeeds. Measured both directly.
2. **The compositor exposes no working shader hook.** The historical one (CGS window filters)
   is now `kCGErrorNotImplemented` for everything, and its one accepted name is a no-op. There
   is nothing left to attach a shader to from outside your own process.

## What is genuinely buildable on this exact config (that stock macOS forbids)

- Inject a Metal-shader pass into a **specific** third-party or Apple app that lacks
  library-validation, by wrapping its `CAMetalLayer` present (Test 3). Per-app, near-native
  latency, but non-distributable and config/version-fragile.
- Route the desktop through a **virtual display** and reshade the captured frames (Test 1).
  This is the only user-space "whole-desktop, total-z-order" path, at the cost of a private
  display-takeover and an input round-trip.

## What remains impossible even with SIP off

- A custom shader stage inside WindowServer's composite pass over arbitrary windows (Test 4 + Test 2).
- Reading another app's live window surface without its cooperation or capture consent.

## Bottom line for Spectra

Spectra already ships the right architecture (ScreenCaptureKit → Metal → overlay). None of
the experimental paths beats it as a *product*:

- Path 2 is dead, so there is no cheap compositor filter to adopt (except `CGSSetWindowBackgroundBlurRadius`
  for Spectra's own chrome vibrancy).
- Path 3 gives lower latency but only for one chosen app and only on a SIP-off + arm64e-preview machine.
- Path 1 gives whole-desktop total-z-order but adds an input round-trip and depends on private
  display APIs and a risky takeover.

If Spectra wants an opt-in "research mode" for power users who have already disabled SIP (like
this machine), the **virtual-display source (Path 1)** is the most defensible add-on: it reuses
Spectra's existing capture→Metal→present engine, with the VD as an alternate source, and avoids
per-app fragility. Keep it clearly separated from the default capture-overlay path.

## Files

- `01_virtual_display/` — `vd_create.m`, `FINDINGS.md`
- `02_cgs_window_filter/` — `cgsfilter.m`, `FINDINGS.md`
- `03_per_app_injection/` — `target.m`, `inject.m`, `FINDINGS.md`
- `04_windowserver_injection/` — `probe.c`, `debugger.entitlements`, `FINDINGS.md`
- `findings/imgstat.swift` — headless screenshot pixel-reader used for visual verification
