# Test 3 — Per-app code injection (yabai pattern) (EMPIRICAL)

**Machine:** MacBook Air M3, macOS 26.5.1 (25F80). **SIP off**, **`boot-args=-arm64e_preview_abi`**,
**`amfi_get_out_of_my_way` NOT set**.
**Verdict: per-app injection (incl. into Apple platform binaries like Dock) WORKS on this
config. WindowServer remains the sole exception.** Demonstrated live with a dylib that hooks
`-[CAMetalLayer nextDrawable]`, the exact place a per-app shader pass would wrap present.

## What was run

- `target.m` — a non-hardened app that drives a `CAMetalLayer` (calls `nextDrawable` in a loop).
- `inject.m` → `inject.dylib` (arm64) and `inject_arm64e.dylib` (arm64e) — a `DYLD_INSERT_LIBRARIES`
  payload whose constructor proves execution and swizzles `-[CAMetalLayer nextDrawable]`.

## Results — where the wall actually is

| Target | dylib arch | Result |
|--------|-----------|--------|
| my non-hardened `./target` | arm64 | **INJECTED** — constructor ran, `nextDrawable` hooked every frame |
| my **hardened-runtime** `./target_hardened` (ad-hoc, `0x10002 runtime`) | arm64 | **INJECTED** — SIP-off did NOT strip the insert for an ad-hoc third-party hardened binary |
| Apple `/bin/echo` (arm64e platform binary) | arm64 | blocked: `incompatible architecture (need 'arm64e')` |
| Apple `/bin/echo`, `/usr/bin/true` | **arm64e** | **INJECTED** — constructor executed inside the Apple platform binary |

The hook output (Case 1) confirms the render-call interception:
```
[inject] *** dylib executing inside pid=81074 ***
[inject] swizzled -[CAMetalLayer nextDrawable] — present path is now under our control
[inject] HOOK -[CAMetalLayer nextDrawable] #1 -> 0x1051a7a90  (a Metal shader pass would be inserted here)
[target] frame 0 nextDrawable=0x1051a7a90
... (every frame intercepted)
```

## The real gate is library-validation (`0x2000`), not "Apple vs not"

Code-signing flags explain everything:

```
echo          flags=0x0(none)               -> foreign dylib loads
true          flags=0x0(none)               -> foreign dylib loads
Dock          flags=0x0(none)               -> foreign dylib loads  (this is the yabai foothold)
WindowServer  flags=0x2000(library-validation) -> foreign dylib REJECTED
```

So on this config the injection rules are:
1. **SIP off + `-arm64e_preview_abi` is sufficient** to load a non-Apple ad-hoc dylib into
   targets that lack library-validation — including Apple platform binaries (echo/true/Dock).
   `amfi_get_out_of_my_way` was NOT needed. The arm64e boot-arg is the key enabler; the dylib
   just has to match the target arch (arm64e for Apple binaries).
2. **Hardened runtime alone does not stop it** here (ad-hoc third-party binary still injected).
3. **Library-validation (`0x2000`) does stop it.** Only Apple-signed dylibs load into such a
   process. WindowServer has it; Dock/echo/true do not.

## Why WindowServer still loses, tying back to Test 4

WindowServer is unreachable by BOTH injection vectors, for independent reasons:
- **DYLD vector:** you can only set `DYLD_INSERT_LIBRARIES` on a process you launch. WindowServer
  is launched by launchd at boot; you cannot set its env without editing its launchd plist and
  restarting it (which logs out the session). And even then its `0x2000` library-validation
  rejects any non-Apple dylib.
- **task_for_pid vector (yabai's thread-hijack):** Test 4 showed `task_for_pid(WindowServer)`
  is DENIED even with a debugger entitlement on this SIP-off machine, while `task_for_pid(Dock)`
  SUCCEEDS. No task port ⇒ no thread hijack.

So Dock is injectable two ways (foreign dylib allowed + task port obtainable); WindowServer
is injectable zero ways.

## Relevance to Spectra / the compositor-shader goal

- Per-app injection into a *specific* non-library-validated app (a game, a media player, a
  browser's GPU process if not LV) is feasible on this machine, and you can wrap its
  `CAMetalLayer` present to add a Metal pass. This is a real route to shading ONE chosen app's
  window with near-native latency (in-process, no capture round-trip) — but it is per-app,
  requires that app to lack library-validation, needs the SIP-off + arm64e-preview config on
  every user's machine, breaks per OS update, and is non-distributable. Research-only.
- It is NOT a route to system-wide shading and NOT a route into the compositor.

## Not done (deliberately)

- Live injection into Dock/yabai's own session: would require killing/relaunching Dock or a
  thread-hijack into the live Dock; both risk disrupting the sleeping user's session. The
  capability is already proven by the equivalent platform-binary injections + the Test-4 Dock
  task-port success, so live Dock injection adds risk without adding evidence.
