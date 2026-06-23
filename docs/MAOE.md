# MAOE — Spectra Semantic & Interaction Layer

Spec and implementation plan for evolving Spectra from a full-screen "medium" re-render
engine into the macOS Aesthetic Overlay Engine (MAOE): coherent per-theme worlds with
their own cursor, interaction language, window chrome, and system-UI treatment.

Status: planning. No code written yet. This document is the source of truth for the build;
a separate instance implements it end to end (see `docs/MAOE_IMPLEMENTATION_PROMPT.md`).

---

## 1. Where Spectra is today

Spectra already ships the entire **medium layer** of the original MAOE master spec. Every
world it named already exists as a tuned full-screen shader chain in
[BuiltInPresets.swift](../Sources/Presets/BuiltInPresets.swift) — **twelve world presets in
all** (four cinematic, four retro, four artistic; the §12 table is the authoritative list),
plus four utility presets — running on a mature capture → resolve → encode → present
pipeline ([ARCHITECTURE.md](../ARCHITECTURE.md)).

What does not exist is the **semantic, per-element, interaction layer**: window-scoped
chrome, a per-theme cursor, an event-driven interaction language, system-UI restyling, and
a motion budget. Verified facts that shape this plan:

- **Rendering is 100% full-screen-space.** Every pass draws a full-screen triangle at
  display resolution. No shader can see a window. `SpectraUniforms` carries no geometry.
- **The event model is binary.** The render loop is either continuous (an effect marks
  `isEffectivelyAnimated`) or fires one forced redraw (`needsRedraw`). There is no decaying
  one-shot animation gate. ([DisplayRenderer.swift:597](../Sources/Render/DisplayRenderer.swift))
- **The pointer pipeline already proves the pattern.** `PointerInputSampler` →
  `FrameContext` → uniform param slots feed `fx_env_splash` / `fx_env_bubbles`, which run
  their own decay envelopes. Only the **left** button is tracked.
- **`controllerKind` is the non-GPU behavior seam.** A descriptor with a `controllerKind`
  rides in a chain but drives a side-effecting controller instead of a GPU pass; the
  resolver drops it and `SystemEffectsController` reconciles it.
  ([EffectDescriptor.swift:9](../Sources/Core/Effects/EffectDescriptor.swift))
- **A `Preset` is metadata + an `EffectChain` and nothing else.**
  ([Preset.swift:38](../Sources/Presets/Preset.swift))
- **`CGWindowList` already yields window rects with no permission prompt**
  ([AdaptiveTintOverlay.swift:182](../Sources/System/AdaptiveTint/AdaptiveTintOverlay.swift)).
  Accessibility (AX) is **not** used anywhere.

The architecture is ready for this work. The seams above are the right ones; MAOE extends
Spectra, it does not re-architect it.

---

## 2. Scope decisions (locked by the owner)

1. **CRT/VHS interaction = press-hold line warp.** Holding **any** mouse button (left,
   right, or other) causes a small inward distortion of the **line pattern only** (scanlines
   / ink), localized to a radius around the cursor, decaying on release. The image content
   does not move; only the lines bend. This replaces the generic "inward warp on click" idea.
   All click- and press-driven effects in this build respond to any mouse button, not just
   the left (see §5.2).
2. **No Accessibility (AX) for now.** Everything ships on `CGWindowList` geometry. AX and
   anything depending on it (typography overlay, sub-window semantic targeting) is **out of
   scope** for this build and parked in §11.
3. **Soft-locked worlds.** Switching a World preset applies its full behavior bundle
   atomically. The user can still drop into the editor; there is no hard immutable mode.
4. **Notifications and dialogs are cut entirely.** They render in other processes above the
   overlay and need fragile private SPIs. Not built, not stubbed.

Explicitly **out of scope** (see §11): AX, typography overlay, system-font replacement,
sub-window control targeting (e.g. traffic-light glows), per-icon effects, notification
styling, dialog styling, generative scene replacement, per-element redesign of app chrome.
Window-rect-derived regions (borders, shadows, a heuristic title-bar strip) stay in scope.

---

## 3. Non-negotiable invariants

Every change must hold these. They are existing, hard-won constraints.

- **The overlay is never captured.** Self-exclusion is by app PID in the SCK filter. Any
  new overlay window (menu-bar / Dock style layers) must be excluded the same way, or it
  creates a GPU feedback loop.
- **Click-through is preserved.** Overlay windows set `ignoresMouseEvents = true`. New
  visual overlays are composited pixels only; they never intercept input.
- **Coordinate spaces are explicit.** `CGWindowList` is CG top-left origin; AppKit is
  bottom-left; the Metal chain is display-local top-left UV. Every geometry consumer
  normalizes to display-local UV using the existing transform
  ([AdaptiveTintOverlay.swift:199](../Sources/System/AdaptiveTint/AdaptiveTintOverlay.swift),
  [DisplayRenderer.applyPointer](../Sources/Render/DisplayRenderer.swift)). One height-flip
  bug misplaces every effect.
- **The render clock stays alive.** Do not reintroduce hide-on-space-switch or periodic
  carry. Honor the watchdog/rebuild path already in `DisplayRenderer` / `RenderEngine`.
- **Idle cost stays at zero.** Effects that are conceptually one-shot must run off the decay
  gate (§5.2), never force continuous rendering.

---

## 4. The shape of the work

Everything fans out from **three foundations**. Build them first, in order; the feature
layers depend on them.

```
Foundation 1: Geometry feed   ─┐
Foundation 2: Event clock      ├─► Cursor · Interaction · Window chrome · System-UI · Motion
Foundation 3: WorldSpec        ─┘
```

---

## 5. Foundations

### 5.1 Geometry feed (window rects into the GPU)

**Goal.** Make per-window rectangles available to any shader, sourced from `CGWindowList`,
no permission prompt.

**Files.**
- New `Sources/Scene/WindowGeometryProvider.swift` — promote the existing
  `TintGeometry.spaceWindows(displayID:)` walk into a reusable, background-throttled provider that
  publishes a lock-free snapshot of display-local-UV window rects (and a count) per display.
  Mirror `PointerInputSampler`'s enable-on-demand + immutable-`Snapshot` pattern. Throttle
  like `AdaptiveTintOverlay` (≈20 Hz idle, 60 Hz while a button is held). Self-exclude
  `kCGWindowOwnerName == "Spectra"`.
- Edit `Sources/Render/EffectChainRenderer.swift` — extend `FrameContext` with
  `windowRects: [SIMD4<Float>]` and `windowCount: Int`. Bind a packed `MTLBuffer` of those
  rects at **fragment buffer index 2**. Today only buffer index 0 (`SpectraUniforms`) and 1
  (the fused-color-ops buffer) are bound; index 2 is free. **Verify before allocating** by
  grepping `setFragmentBytes` / `setFragmentBuffer` in `EffectChainRenderer` and
  `ShaderLibrary`, and note that an imported custom shader could in principle bind index 2 —
  guard accordingly. `CursorCompositor` is the precedent for passing a geometry uniform via a
  buffer alongside fragment textures (it binds its own `CursorUniforms` at index 0, not 2),
  not a precedent for index 2 specifically. Bind only when a resolved effect declares it needs
  rects (add `requiresWindowRects: Bool` to `EffectPass`, default false), so existing effects
  pay nothing.
- Edit `Sources/Render/DisplayRenderer.swift` — populate `FrameContext.windowRects` from the
  provider snapshot each frame, same place `applyPointer` runs.

**Cap.** Fixed max window count (64 → 1 KB buffer). Clamp and `log()` overflow; never
silently truncate.

**Acceptance.** A debug shader tinting inside window rects tracks windows as they move
(with the expected ~1-2 frame `CGWindowList` lag). Idle CPU unchanged when no rect-consuming
effect is active.

### 5.2 Event clock (discrete events + decay render gate)

**Goal.** Turn the binary render loop into one that can fire a bounded, decaying burst on a
discrete event, then return to idle; and capture the events themselves.

**Files.**
- Edit `Sources/Render/DisplayRenderer.swift` — add `decayExpiresAt: CFTimeInterval`
  alongside `needsRedraw`. The link callback treats the frame as live while
  `CACurrentMediaTime() < decayExpiresAt`, then drops to idle. A helper `armDecay(_ seconds:)`
  sets it. This is the single mechanism behind every event effect and the event-only CRT/VHS.
- Edit `Sources/Render/PointerInputSampler.swift`:
  - **Generalize click/press capture to any mouse button.** Add `.rightMouseDown` and
    `.otherMouseDown` to both down monitors, and detect the held state with
    `NSEvent.pressedMouseButtons != 0` (any button) instead of `& 0x1` (left only). Stamp
    `lastDownTime` / `lastDownPos` on any button down. This makes the existing `clickAge`,
    `clickPoint`, and `pressed` signals button-agnostic, so **every** click- and press-driven
    effect inherits any-button behavior with no new field: the interaction effects (§7.1), the
    press-hold line warp (§7.2), and the existing splash / bubbles all now fire on any mouse
    button. (Splash and bubbles responding to right/middle clicks is intended.)
  - Add an `NSEvent.scrollWheel` global+local monitor; add `scrollDelta: CGVector` and
    `lastScrollTime: Double` to `Snapshot`.
- Edit `Sources/Render/RenderEngine.swift` — in `activeSpaceDidChange`, after the carry
  settles (not at notification time), stamp the space-change time. `RenderEngine` and
  `DisplayRenderer` are different objects with no shared mutable channel today, so add a
  `nonisolated(unsafe) var spaceChangeTime: Double = -1` on `RenderEngine` (lock-guarded or
  atomic) and inject a read-only accessor into each `DisplayRenderer` at init, mirroring how
  the pointer sampler is already injected, so the link thread reads it without touching
  `RenderEngine`.
- Edit `Sources/Render/EffectChainRenderer.swift` — extend `FrameContext` with
  `scrollAge`, `scrollDelta`, `spaceAge`, `pressAge` (seconds since each event; large
  sentinel when none; `pressAge = CACurrentMediaTime() - lastDownTime` while held, else a
  large sentinel). Inject these into the first free uniform param slot **after** the existing
  pointer/trail block. The block runs `pointerSlotBase` (16) + 6 named fields + `trailCount`
  UV pairs × 2, so with the current `trailCount = 12` the first free slot is
  16 + 6 + 24 = **46**; recompute from `PointerInputSampler.trailCount` rather than hardcoding,
  since changing the trail length shifts it. Gate injection on an `eventEffectFunctions` set,
  mirroring the existing `pointerEffectFunctions` allowlist
  ([EffectChainRenderer.swift:81](../Sources/Render/EffectChainRenderer.swift)).

**Acceptance.** Clicking, scrolling, or switching Spaces produces a measurable decaying
render window, then the link idles. `pressed` is true for a hold of any mouse button
(left, right, or other), and `clickAge` resets on any button down.

### 5.3 WorldSpec (per-theme behavior bundle)

**Goal.** Let a preset declare its cursor, interaction set, system-UI defaults, and motion
budget without breaking existing persistence.

**Files.**
- New `Sources/Presets/WorldSpec.swift` — a `Codable, Sendable, Hashable` struct:
  ```
  struct WorldSpec {
      var cursor: CursorSpec?            // §6
      var systemUI: SystemUIDefaults?    // §9
      var motion: MotionBudget?          // §10
      // interaction effects ride as chain members, not here (soft-lock §8)
  }
  ```
- Edit `Sources/Presets/Preset.swift` — add `var world: WorldSpec? = nil`. Optional, so all
  existing built-in and user-preset JSON decodes unchanged (`JSONDecoder` skips the absent
  key → `world == nil`). Preset identity is unaffected: `matchesPreset` lives on `EffectChain`
  ([EffectInstance.swift:106](../Sources/Core/Effects/EffectInstance.swift)) and compares
  chain contents only, never `Preset`-level metadata.

**Acceptance.** Existing user presets load with `world == nil`. A built-in with a `world`
round-trips through JSON.

### 5.4 Window lifecycle events & ghost-border mitigation

**The problem.** Per-window chrome (borders, shadows) is driven by `CGWindowList` rects,
which lag the WindowServer by 1-2 frames and do not expose the genie/scale minimize morph.
Caching or interpolating a rect across a close/minimize leaves a border floating where the
window used to be — a **ghost border**.

**macOS reality.** There is no public API for the close/minimize animation geometry; the
morph is rendered by the WindowServer and never reported as a rect sequence, so chrome
cannot truly "follow" a genie minimize. Two things **are** readable: a window's
`kCGWindowAlpha` (which ramps down during a close fade) and its presence/absence in the list.

**Mechanism (eliminates ghost borders, still delivers close/minimize effects):**
1. **Never cache chrome past the frame.** Compute chrome every frame from the *live* window
   list only. A window absent from the current list contributes no chrome, so a border with
   no window is structurally impossible. Lag stays on the appearance/move side, where it is
   invisible.
2. **Opacity = `kCGWindowAlpha`.** Multiply each window's chrome opacity by its current alpha
   (the provider already reads it, per `AdaptiveTintOverlay`). A closing window fades out and
   its border fades out *with* it — the close-fade "follows" for free, with no hard pop.
3. **Diff the window set for lifecycle events.** `WindowGeometryProvider` tracks window ids
   tick-to-tick. When an id leaves the set (alpha crosses ~0 → `windowClosed`; area collapses
   sharply toward the Dock → `windowMinimized`) or a new id enters (→ `windowOpened`, used by
   Matrix decode), emit a one-shot event carrying the rect (and, for minimize, the Dock
   direction). The event clock (§5.2) fires a decaying burst at that rect.
4. **Bursts are at-last-location, not morph-following.** Per-world close/minimize effects
   (Cyberpunk glitch flash, Frutiger bubble-pop / bubble-trail-toward-Dock, Noir
   caption-boundary collapse, Golden Hour shadow collapse) are short decaying bursts at the
   last rect; this reads well and needs no morph geometry.
5. **Sample fast during the event.** On a detected lifecycle change, run the provider at
   60 Hz for the decay window so the alpha ramp and burst are smooth, then drop to idle.

**Files.** Extend `WindowGeometryProvider` (§5.1) with the id-diff + alpha + lifecycle-event
emission; the burst shaders live in `Interaction.metal` (§7.1), driven by the event clock. No
new permission, no private API.

**Acceptance.** Closing or minimizing a window never leaves a border behind; the close fade
carries the border with it; each world's close/minimize burst fires at the last rect.

---

## 6. Cursor system (per-theme)

**Goal.** Each world can specify a styled cursor; intensity `none` reverts to the system
cursor and disables compositing. Click accuracy is never affected (the rendered cursor is
cosmetic; the OS routes input via the hidden hardware cursor's hotspot).

**Model.** New `Sources/Render/CursorStyle.swift`:
- `enum CursorStyle { case system, neonCyan, pixelGreen, warmTint, sprite(SpriteKind) }`
- `enum SpriteKind { case noirObject, retro8090, aero2000s, typewriter, serif }` — bespoke
  per-world cursor art: Noir 1930s real-world object, CRT/VHS 80s-90s icon, Frutiger 2000s
  maximalist icon, Reading typewriter, Fuji serif pointer.
- `enum CursorIntensity { case none, minimal, full }`
- `struct CursorSpec { var style: CursorStyle; var intensity: CursorIntensity; var pressAnim: Bool = false }`
  — `pressAnim` lets a sprite cursor depress/scale on press (Noir's click depression, scroll
  wiggle) driven by `pressAge` in the compositor.

**Bespoke-sprite rule (usability, non-negotiable).** A sprite cursor replaces only the
**arrow**. macOS swaps the cursor to I-beam / resize / loading shapes contextually, and a
single sprite cannot represent those. So sprite styles apply only while
`NSCursor.currentSystem` is the standard arrow; for any other system shape, fall through to
that real shape (optionally tinted by the world). The restyle variants (`neonCyan`,
`pixelGreen`, `warmTint`) operate on whatever the system cursor currently is, so they cover
all states. `CursorSampler` already reads `NSCursor.currentSystem`, so the arrow-identity
check lives there.

**Files.**
- Edit `Sources/Render/CursorSampler.swift` — add `style` / `intensity` / `pressAnim` to
  `Snapshot`. `intensity == .none` (or `style == .system`) returns a nil sprite (compositor
  early-outs). For a `sprite` style — and only while the system cursor is the standard arrow,
  per the bespoke-sprite rule — `refreshSprite()` loads a pre-rasterized `CGImage` from the
  bundle with an authored hotspot instead of `NSCursor.currentSystem`. Preload sprites at
  init; keep them ≤ 64×64 @2x so the main-thread load never stalls.
- Edit `Sources/Shaders/Cursor.metal` — expand `CursorUniforms` (currently exactly
  `struct CursorUniforms { float4 rect; }`) with `styleIndex (int)`, `intensity (float)`,
  `tint (float4)`. One shader body branches on `styleIndex`: passthrough (unchanged), neon
  (SDF ring expand, capped ≤ 6 px so the visual tip stays honest), pixel (UV quantize +
  threshold), tint (color-matrix). Sprite styles do no shader work; the sprite (and any
  `pressAnim` depression, scaled by `pressAge`) is substituted/driven upstream in the
  compositor. **Expand the Swift-side mirror in the same
  commit:** `CursorCompositor.swift` declares a private `struct CursorUniforms { var rect:
  SIMD4<Float> }` ([CursorCompositor.swift:20](../Sources/Render/CursorCompositor.swift)); it
  must gain the identical fields in the same order, or the Metal buffer is misread at the
  Swift/Metal boundary.
- Edit `Sources/Render/CursorCompositor.swift` — accept `CursorSpec`; resolve the pipeline
  via `ShaderLibrary.pipeline(fragment:)` (cached); pass the expanded uniforms.
- Edit `Sources/Engine/SpectraEngine.swift` — `applyCursorState()` resolves the active
  preset's `world?.cursor` (nil → `.system/.full`) and fans `(style, intensity)` to every
  `DisplayRenderer`'s compositor. Keep the existing auto-engage-for-warp path.
- New assets `Sources/Resources/CursorSprites/` — one `@2x.png` per `SpriteKind`
  (`noir-object`, `retro-8090`, `aero-2000s`, `typewriter`, `serif`) plus
  `cursor-hotspots.json` (per-sprite hotspot in points). Validate each hotspot to the visual
  tip; a 1 pt error reads as a misclick. Noir's object needs a second "pressed" frame (or a
  parametric depress in the compositor) for its click animation.
- Edit `Sources/UI/Settings/SettingsView.swift` — replace the single `customCursor` toggle
  with a style picker + intensity control that acts as a **global override**; per-preset
  `world.cursor` is the default when no override is set. Migrate the persisted
  `customCursor: Bool` with a `SettingsStore` schema-version bump (current version is 6 →
  bump to 7; no reset of existing preference). Migration rule: `customCursor == true` →
  global override `CursorSpec(style: .system, intensity: .full)` (preserves "draw the real
  cursor through effects"); `customCursor == false` → no override (nil; defer to the world
  default).

**Acceptance.** Loading Matrix shows a green pixel cursor; intensity `none` shows the real
system cursor with no composite pass. Clicks land on the visual tip for the pen-nib sprite.

---

## 7. Interaction language

Two parts: a small family of event-driven overlay effects (§7.1), and the press-hold line
warp that is special-cased into the line-bearing shaders (§7.2).

### 7.1 Event overlay effects

**Files.**
- One new `Sources/Shaders/Interaction.metal` (not one file per effect). The age-based decay
  envelope is **inline** inside `fx_env_splash`
  ([Environment.metal:441](../Sources/Shaders/Environment.metal)); there is no reusable
  `pressEnvelope()` to call, so author a new inline helper in `Interaction.metal` following
  that idle-gate + age-comparison pattern (do not expect a function to copy). Glyph effects
  need the 5×7 bitmap font + sampler `glitch_glyph()`
  ([Glitch.metal:380](../Sources/Shaders/Glitch.metal)); all `.metal` files compile into one
  library sharing a namespace, so copying the file-scope `constant glitch_glyphFont[]` array
  into a second file is a duplicate-symbol error — **move the font + `glitch_glyph()` into
  `SpectraCommon.h`** (or a small shared header) and include it from both. Functions, each
  driven by the existing pointer/event uniforms and self-decaying off `clickAge` /
  `scrollAge` / `spaceAge`:
  - `fx_int_clickPulse` — warm/gold radial ring (Golden Hour).
  - `fx_int_clickRipple` — dual-color cyan→magenta ripple with chromatic split (Cyberpunk).
  - `fx_int_glyphBurst` — 5×7 bitmap glyphs exploding from the click (Matrix), via the shared
    `glitch_glyph()` helper.
  - `fx_int_inkRipple` — pressure-blob ink darkening with paper modulation (Noir / artistic).
  - `fx_int_dragTrail` — warm ~120 ms particle trail along the pointer trail pairs.
  - `fx_int_liquidTrail` — UV-warp surface-tension trail (extends the splash rope).
  - `fx_int_glyphTrail` — glyphs stamped along the trail, fading with age (Matrix).
  - `fx_int_shadowDeform` — drag-path UV-displacement darkening; a soft shadow that deforms
    under the drag (Noir).
  - `fx_int_scrollDrift` — column-shifted glyph drift triggered by `scrollAge` (Matrix).
  - `fx_int_hyperspaceStreak` — radial velocity streaks on `spaceAge` (Cyberpunk).
  - `fx_int_spaceGlyphRain` — dense glyph-rain burst on `spaceAge` (Matrix).
  - `fx_int_lightLeak` — warm film light-leak streak on pointer movement (~50 ms decay) (Fuji).
  - `fx_int_filmSquares` — film-sprocket squares filling the space-switch transition (Fuji).
  - **Window-lifecycle bursts**, fired by the §5.4 `windowClosed` / `windowMinimized` events
    at the window's last rect (the event clock writes that rect + the Dock direction into the
    event uniform slots): `fx_int_bubblePop` (Frutiger close), `fx_int_bubbleTrail` (Frutiger
    minimize, aimed at the Dock), `fx_int_windowGlitch` (Cyberpunk close/minimize),
    `fx_int_shadowCollapse` (Golden Hour), `fx_int_captionCollapse` (Noir).
  - **Per-world signatures:** `fx_int_iris` (Noir iris-in/out on `spaceAge`); `fx_int_decode`
    (Matrix window-open glyph scramble→resolve, on the §5.4 `windowOpened` event);
    `fx_int_cmykShift` (Print Art CMYK registration offset by pointer/scroll velocity);
    `fx_int_speedLines` (Comic speed-lines on fast cursor); `fx_int_powBurst` (Comic halftone
    "POW" on click). Two reuse existing effects gated on a signal rather than new shaders: CRT
    **phosphor trails** (gate `retro.phosphorGlow` on pointer velocity) and Matrix
    **idle-intensified rain** (gate `glitch.digitalRain` on input-idle).
- New `Sources/Effects/Categories/InteractionEffects.swift` — one `EffectDescriptor` per
  function in a new `.interaction` `EffectCategory` case. Register each function name in the
  appropriate `pointerEffectFunctions` / `eventEffectFunctions` set so the sampler engages
  automatically when present.

Follow the `spectra-add-effect` conventions: `fx_int_<name>` signature, declaration-order
flat param-slot binding, compile-check the shader, then build.

### 7.2 Press-hold line warp (the CRT/VHS interaction)

**Behavior.** While **any** mouse button is held, the line pattern compresses inward toward
the cursor within a soft radius; the effect eases in on press and decays out on release.
Image content does not move. (Any-button capture is handled centrally in §5.2, so this
effect just reads the standard `pressed` / `pressAge` signals.)

**Mechanism (lines only).** The line-bearing CRT functions already build their scanlines
through the inline helper `fx_crt_scanline(uvY, lineCount, strength)`
([Retro.metal:98](../Sources/Shaders/Retro.metal)), called by `fx_crt_crt`,
`fx_crt_crtAdvanced`, `fx_crt_scanlines`, `fx_crt_analogTV`. The warp displaces the **`uvY`
fed to that helper** locally near the cursor; `spectra_tex(src/orig, in.uv)` is left
untouched. Because only the scanline coordinate is pinched, content stays put and the lines
bend. Concretely:

```
// clickPoint = pointer UV (slots 16-17). pressed / pressAge come from the §5.2 pointer
// block, so §5.2 must be implemented first or these read unset slots. lineY = the SAME y
// the function already feeds to fx_crt_scanline (it differs per function — see table).
float d       = distance(in.uv, clickPoint) / warpRadius;     // radius in UV
float falloff = smoothstep(1.0, 0.0, d);                      // 1 at cursor, 0 at edge
float env     = pressEnvelope(pressAge, pressed);             // ease-in while any button held, decay on release
float pinch   = warpStrength * falloff * env;                 // small, e.g. ≤ 0.12
float warpedY = clickPoint.y + (lineY - clickPoint.y) * (1.0 - pinch);
// feed warpedY to fx_crt_scanline in place of lineY
```

The four callers feed **different** y-coordinates, so apply the pinch to the right variable
in each — warping `in.uv.y` blindly fights the barrel curvature and tears at the tube edge:

| Function | `lineY` to pinch |
| --- | --- |
| `fx_crt_crt`, `fx_crt_crtAdvanced` | `wuv.y` (already barrel-warped) |
| `fx_crt_scanlines` | `in.uv.y` |
| `fx_crt_analogTV` | local `uv.y` (after the roll jitter) |

**Files.**
- Edit `Sources/Shaders/Retro.metal` — gate the warp behind a new parameter
  (`linePressWarp`, default 0 so existing presets are unchanged) on the four scanline
  functions; read `pressed` / `clickPoint` / `pressAge` from the injected pointer block
  (now any-button per §5.2).
- Edit `Sources/Render/EffectChainRenderer.swift` — add the four `fx_crt_*` scanline
  functions to `pointerEffectFunctions` so the sampler engages and the block is injected;
  drive the decay gate (§5.2) off the any-button `pressed` state.
- `CRT Display` already chains scanline-bearing functions, so set `linePressWarp > 0` and a
  sensible `warpRadius` on its `retro.crtAdvanced` row. **VHS Tape has no `fx_crt_scanline`
  call** — its chain is colour + `vhs.colorSmear` + `vhs.tracking` + `noise.filmGrain`
  ([BuiltInPresets.swift:130](../Sources/Presets/BuiltInPresets.swift)), so the scanline warp
  has no hook there. Give VHS its line warp by extending `fx_vhs_tracking` with the identical
  local-pinch-on-press applied to its horizontal tracking-band displacement (VHS's "lines"
  are the tracking bands). Validate in the test harness; if tracking reads poorly, fall back
  to adding a faint, high-count `retro.scanlines` pass to the VHS chain as the warp hook.
- Generalization (optional, same parameter): the artistic line shaders
  (`style.lineart` contour ink, `style.cel` key-block ink) can adopt the identical
  `linePressWarp` so Pencil Sketch / Print Art bend their ink under press. Implement only if
  cheap; scanlines are the required target.

**Acceptance.** With CRT Display active, holding any mouse button bunches the scanlines
toward the cursor in a small radius; releasing eases them back; the desktop content under
the cursor does not shift. Idle (no button) cost is unchanged.

---

## 8. Soft-locked worlds

**Behavior.** Switching to a World preset applies its full bundle atomically (cursor +
system-UI defaults + motion budget + chain, including any interaction-effect chain members)
in one reconcile pass before the first rendered frame, so no intermediate state shows. The
user can still open the editor and modify the chain; doing so does not destroy the world,
it just diverges from it (existing edit semantics).

**Files.**
- Edit `Sources/Engine/SpectraEngine.swift` — consolidate preset application so `world`
  facets apply atomically with the chain. In the preset-switch path, after resolving the new
  chain in `updatePipelines`, synchronously call `applyCursorState()` and
  `desiredSystemState()` → `systemEffects.apply()` **before returning**, on the main actor,
  so the next display-link tick sees the new chain, cursor, and system-UI together and no
  intermediate frame renders the old cursor against the new grade. Interaction effects are
  ordinary chain members authored into the preset, so switching carries them for free (no
  separate event-rule map needed).

**Acceptance.** Switching Cyberpunk → Noir swaps grade, cursor, interaction effects, and
system-UI in one frame with no flash of the previous world's cursor or system state.

---

## 9. System-UI styling (menu bar + Dock)

**Goal.** Per-theme treatment of the menu bar and Dock via click-through overlay layers,
driven through the existing `controllerKind` seam. Notifications and dialogs are cut (§2).

**Files.**
- Edit `Sources/Core/Effects/EffectDescriptor.swift` — add `EffectControllerKind` cases
  `.menuBarStyle`, `.dockStyle`.
- Edit `Sources/System/SystemEffectsController.swift` — add `menuBarStyle:`, `dockStyle:`,
  and `lightModel:` optional fields to `SystemEffectsState`; add apply/diff/restore branches
  following the existing nil-means-off pattern.
- Edit `Sources/Effects/Categories/SystemEffects.swift` — new descriptors (no GPU passes,
  `controllerKind` set) for the style variants: menu bar (soft directional shadow, caption
  strip, reflective, pastel); Dock (grounded ambient shadow, stage-boundary frame, neon
  outline, matte pastel).
- New `Sources/System/MenuBar/MenuBarStyleOverlay.swift` — a borderless, click-through
  (`ignoresMouseEvents = true`) `NSWindow` above the menu-bar chrome, drawing per-theme
  shapes as a `CALayer` composite. SCK self-exclusion is automatic: the filter excludes the
  whole Spectra PID, so any in-process window is already excluded (do not add it to the
  `exceptingWindows` list). Reuse `OverlayWindow`'s existing level constants (it already
  derives `aboveMenuBarLevel` from the menu-bar window level) rather than inventing raw
  numbers. Menu-bar rect from `NSScreen.visibleFrame` vs `frame` delta.
- New `Sources/System/Dock/DockStyleOverlay.swift` — click-through `NSWindow` (auto-excluded
  from capture by the PID filter, same as above); Dock rect and orientation from
  `CGWindowList` filtered on `kCGWindowOwnerName == "Dock"` (precedent:
  [CursorVisibilityEnforcer.swift:148](../Sources/App/CursorVisibilityEnforcer.swift)).
  Derive levels via `CGWindowLevelForKey(.dockWindow)` as `OverlayWindow` already does: behind
  the Dock (`dockWindow − 1`) for shadows, in front (`dockWindow + 1`, still click-through)
  for outlines. The motion-dependent reflection variant reads `PointerInputSampler`'s
  published snapshot to modulate a gradient/replicator layer on its own `CADisplayLink`
  (separate from the Metal clock).
- New `Sources/System/LightModel.swift` — a shared `struct LightModel { angle; intensity;
  color; spread }`, carried on `SystemEffectsState`, read by every overlay so shadows and
  highlights agree across surfaces. Update on the main actor; each overlay reads it in its
  own callback.
- Edit `Sources/Engine/SpectraEngine.swift` — `desiredSystemState()` aggregates each world's
  `world?.systemUI` defaults at lower priority than explicit stack rows (user edits win).
  Per-theme menu-bar/Dock overlays require the overlay to sit above the chrome; reconcile
  with the user's `coverMenuBarAndDock` setting rather than silently overriding it.

**Acceptance.** Golden Hour shows a soft directional menu-bar shadow and a grounded Dock
shadow from one consistent light direction; Matrix shows a neon-green Dock outline; switching
away cleanly removes them. None of the overlays appear in the capture stream.

---

## 10. Motion budget & event-driven governor

**Goal.** Each world declares its motion envelope; the engine prefers event-driven effects
over continuous ones and finally wires the dead `reduceMotion` setting.

**Model.** In `Sources/Presets/WorldSpec.swift`:
```
struct MotionBudget {
    var continuousMax: Int?      // 1-3; advisory ceiling on continuous effects
    var cursorIntensity: Float?  // 0-1, maps to CursorIntensity
    var targetGPUms: Double?     // optional per-world governor target
}
```

**Files.**
- Edit `Sources/Core/Effects/EffectDescriptor.swift` — add
  `triggerKind: EffectTriggerKind?` (`.continuous`, `.onClick`, `.onScroll`, `.onSpaceSwitch`,
  `.onPress`). Classify existing descriptors (splash/bubbles → `.onClick`; grain/scanlines →
  `.continuous`).
- Edit `Sources/Render/DisplayRenderer.swift` — extend the idle guard so event-triggered
  effects only re-render while their matching event age is within the decay window (§5.2),
  not every frame.
- Edit `Sources/Engine/SpectraEngine.swift`:
  - Wire `SettingsStore.reduceMotion`: when true, force `continuousMax = 0` and disable
    `.continuous`-trigger effects, leaving event-driven and static effects. Apply a small
    GPU-cost floor so trivially cheap continuous effects (subtle grain) are not killed
    needlessly.
  - Have the budget enforcer run **before** the existing auto governor so the two never
    oscillate. The auto governor is `governAutoQuality()` in
    [SpectraEngine.swift](../Sources/Engine/SpectraEngine.swift), called from `tick()` on the
    ~0.5 s cadence; hook the enforcer into that same tick ahead of it. The enforcer counts
    continuous effects against `continuousMax` and surfaces a warning; default to warn, not
    force-disable, to avoid yanking effects the user just enabled (the precise policy is a
    small product call; warn first).

**Acceptance.** `reduceMotion` on makes continuous-heavy presets fall back to static +
event-driven and visibly drops idle GPU time. Event effects do not force continuous redraw.

---

## 11. Parked (explicitly not in this build)

These are designed-around, not forgotten. Revisit only on an explicit decision.

- **AX semantic layer** (`AXUIElement` scene graph, sub-window structure, hover/focus state).
  Privilege escalation (reads all apps' text/UI), XL effort, fragile across macOS versions.
- **Typography overlay** (serif re-skin of menu-bar / title / sidebar text). Depends on AX
  for per-text-element bounds; requires a CoreText glyph atlas + a new render pass. Highest
  risk in the original spec. Park until AX is reconsidered.
- **System font replacement** (Fuji-Film / Reading serif OS text). The original MAOE master
  spec forbids system font replacement, and a real per-text restyle needs AX bounds (parked
  above). Cut: those worlds keep their grade and cursor, but not a serif OS font.
- **Sub-window element targeting** (Golden Hour gold traffic-light glow, Matrix all-green
  traffic lights, any per-control restyle). Controls are sub-window elements; locating them
  reliably needs AX. Window-rect-derived regions stay in scope (borders, shadows, a heuristic
  title-bar top-strip), but per-control effects are cut.
- **Per-icon effects** (Golden Hour per-Dock/desktop-icon shadows). Needs per-icon geometry
  (Dock introspection), unavailable from the window-rect feed. Cut.
- **Notification & dialog styling.** Other-process surfaces above the overlay; need private
  SPIs that break across releases. Cut. The only safe future lever is a yabai dialog border
  rule on [YabaiBridge.swift](../Sources/System/Yabai/YabaiBridge.swift), and even that
  matches by app name, not window type. No stub or partial implementation is expected in this
  build.

---

## 12. Per-world authoring

All twelve worlds already ship their grade. Remaining facets to author into each
`WorldSpec` / chain. Per the owner's scope, three things are **excluded** (see §11): system
font replacement, sub-window control targeting (traffic-light glows), and per-icon effects.
Among the utility presets, **Reading** and **Night Light** get a cursor facet (below);
**Studio** and **Crisp Text** stay plain.

| World | Cursor | Interaction (click / drag / scroll / space) | Chrome, system-UI & lifecycle |
|---|---|---|---|
| Golden Hour | `system` | `fx_int_clickPulse` (gold); `fx_int_dragTrail` (warm); scroll none; space standard | 210° `LightModel`; menu-bar soft directional shadow; Dock grounded shadow; window border = directional drop shadow (bottom + left); active-window gold border glow; **ambient dust motes** in the light, settling on window tops (§15.2); close/minimize → `fx_int_shadowCollapse` (§5.4). *Excluded: per-icon shadows, traffic-light glow.* |
| Cyberpunk | `neonCyan` | `fx_int_clickRipple`; drag none; scroll none; `fx_int_hyperspaceStreak` (space, speed-scaled) | neon window edge glow; neon Dock outline; **living desktop: neon rain in the window gaps** (§15.2). *(Grade/cursor kept as spec; gap-rain added by owner.)* |
| Fuji-Film | `sprite(serif)` | click/drag/scroll standard; `fx_int_lightLeak` on pointer movement (~50 ms); space → `fx_int_filmSquares` (sprocket squares) | subtle window shadow; matte-pastel Dock (no glass); pastel menu bar. *Excluded: serif OS font.* |
| Noir | `sprite(noirObject)`, `pressAnim` | click = cursor-object depression + depth (§6); drag none; scroll = subtle cursor-object animation; space → `fx_int_iris` (iris-in/out) over the caption-styled black gap | silent-film caption aesthetic + boundary on menu bar, Dock, and window borders; close/minimize → `fx_int_captionCollapse` (§5.4). |
| The Matrix | `pixelGreen` | small `fx_int_glyphBurst` on click; drag = continuous glyph emanation; `fx_int_scrollDrift` (opposite scroll dir); `fx_int_spaceGlyphRain` in the inter-space black bar; window-open → `fx_int_decode` (glyph scramble→resolve, §5.4); idle → rain intensifies (gate `glitch.digitalRain`) | green window border glow; black Dock + green pixelated outline. *Excluded: all-green traffic lights.* |
| CRT Display | `sprite(retro8090)` | §7.2 press-hold line warp; drag = continuous; scroll none; motion → phosphor trails (gate `retro.phosphorGlow` on pointer velocity) | none required |
| VHS Tape | `sprite(retro8090)` | §7.2 press-hold line warp (via `fx_vhs_tracking`); drag = continuous; scroll none | none required |
| Frutiger Aero | `sprite(aero2000s)` | water splash on click + water drag trail (ships `environment.splash` / `bubbles`, [BuiltInPresets.swift:196](../Sources/Presets/BuiltInPresets.swift)) | clear **reflective** menu bar (not transparent); **very reflective** Dock; window border + header shiny on the top half (header slightly concave, via the heuristic title-bar top-strip); **living desktop: water caustics + rising bubbles in the window gaps** (§15.2); close → `fx_int_bubblePop`; minimize → `fx_int_bubbleTrail` aimed at the Dock |
| Reading (utility) | `sprite(typewriter)` | standard | standard. *Excluded: serif OS font.* |
| Night Light (utility) | `warmTint` (warmer black) | standard | standard |
| Painting | `system` | brush-edge bleed on motion (optional) | soft per-window border bleed |
| Print Art | `system` | optional `linePressWarp` on key-block ink; motion → `fx_int_cmykShift` (CMYK registration offset by pointer/scroll velocity) | flat per-window framing |
| Comic Book | `system` | click → `fx_int_powBurst` (halftone "POW"); fast cursor → `fx_int_speedLines` | panel-style window framing |
| Pencil Sketch | `system` | optional `linePressWarp` on contour ink | paper per-window vignette |

The Frutiger header treatment uses a **heuristic title-bar top-strip** derived from the
window rect (top ~28 pt of a standard window), not element targeting, so it stays within the
no-AX scope; flag it best-effort for non-standard or hidden title bars.

Window chrome shaders (border glow, soft shadow, per-window vignette) live in a new
`Sources/Shaders/WindowChrome.metal` + `Sources/Effects/Categories/WindowChromeEffects.swift`
(new `.chrome` category), reading the geometry buffer from §5.1. **Soft shadow doubles with
the macOS native shadow**; the soft-shadow variant requires `yabai -m config window_shadow
off` and therefore carries a yabai dependency. Gate the soft-shadow descriptor on the
existing `SpectraEngine.systemEffectsStatus` provisioning check (the yabai readiness signal
already surfaced for the system effects); do not add a new provisioning path.

---

## 13. Build, test, verify

- **Build / install / run:** `Scripts/install.sh` (the `build-spectra` skill). It regenerates
  the Xcode project from `project.yml`, replaces `/Applications/Spectra.app`, keeps a single
  instance, and pre-grants TCC to avoid Screen Recording prompts. The overlay is
  uncapturable, so visual confirmation comes from the owner, not from a screenshot tool
  (see the working-style note).
- **Shader tuning off-screen:** `ShaderTestHarness` via the `SPECTRA_SHADERTEST` env over the
  Griffith aerial frames in `/Users/Shared/Aerial/WallpaperFrames` (copy a frame; they
  rotate). Use this to dial the line-warp radius/strength and cursor shaders before touching
  the live app.
- **Adding effects:** follow the `spectra-add-effect` skill — `fx_<category>_<effect>`
  signature, the flat 64-float param-slot contract, declaration-order binding, compile-check
  the shader, build, update effect counts.
- **Per-feature acceptance** is listed inline in each section above.

---

## 14. Build order

Strict dependency order. Each phase is shippable.

**Phase 1 — foundations + no-permission feature set.**
1. §5.1 geometry feed, §5.2 event clock, §5.3 WorldSpec, §5.4 window-lifecycle events +
   ghost-border mitigation (the spine).
2. §6 cursor system (restyle variants + bespoke sprites + `pressAnim`).
3. §7.1 interaction effects (incl. light leak, film squares, and the §5.4 close/minimize
   bursts) + §7.2 press-hold line warp.
4. Window chrome shaders (§12) reading the geometry buffer, opacity-gated by `kCGWindowAlpha`.
5. §8 soft-lock; author Phase-1 facets (cursor, interaction, borders, lifecycle bursts) into
   the worlds per the §12 table.

**Phase 2 — system-UI + motion.**
6. §9 menu-bar + Dock overlays via new `controllerKind`s + `LightModel` (Golden Hour shadows,
   Noir caption, Fuji pastel, Matrix green outline, Frutiger reflective).
7. §10 motion budget + governor integration + `reduceMotion` wiring.
8. Author system-UI + motion facets into the worlds.

**Phase 3 — engine capabilities (§15).** Audio-reactive, focus spotlight, keyboard-reactive
(the one new permission), geometry-aware generative content, the styled-capture convenience,
and world-export of `WorldSpec`. Sequence the individual wins after the worlds feel complete;
context routing, virtual camera, and gallery are roadmap.

**Phase 4 — interface: radical simplification & control (§16).** Collapse to the Worlds
gallery + master intensity, demote the editor to a Studio door, add the assignable hotkey
switcher and the filter-window keybind, and tighten onboarding.

**Parked.** §11 (AX, typography/system-font replacement, sub-window control targeting,
per-icon effects, notifications, dialogs) — not this build.

---

## 15. Engine capabilities (beyond post-processing)

These turn Spectra from a screen filter into a reactive, shareable engine — the difference
that makes a world feel *alive* and makes the product demo itself. Every item reuses an
existing seam and needs no AX. Each is tagged with a tier: **win** (clear, build it),
**roadmap** (bigger, sequence later). All are additive to the §14 plan; start them once the
worlds feel complete.

### 15.1 Ambient inputs — reactive worlds

The engine already injects live signals into every frame (`batteryLevel`, pointer, clock via
`FrameContext`). Add more, the same way, so worlds *respond* instead of just recolor. Each
sits behind a **Settings toggle**, never forced.

- **Audio-reactive (win, toggle).** Enable `capturesAudio` on the **existing** `SCStream` and
  compute a level + a few frequency bands on the audio callback, injected as
  `FrameContext.audioLevel` / `audioBands[]` exactly like `batteryLevel`. SCK system-audio
  rides the Screen Recording grant already held, so no separate prompt is expected (verify on
  the target OS). Worlds opt in via `WorldSpec`: Matrix rain speed, Cyberpunk bloom pulse,
  Frutiger ripples on the beat, VHS jitter on bass. Files: `CaptureSession` (audio path), new
  `Sources/Render/AudioReactor.swift`, `FrameContext`. Global on/off in Settings. *"Your
  desktop moves to your music" is a one-line sell and a great demo clip.*
- **Focus spotlight (win, toggle, cross-world).** Using the §5.1 geometry feed plus
  `NSWorkspace.frontmostApplication` (public, no AX) and `CGWindowList` z-order to identify
  the focused window, dim/desaturate background windows and lift the active one — a masked
  chrome pass over the non-focused rects. Global Settings toggle; per-world default in
  `WorldSpec.focusDim`. Complemented by the manual filter-window keybind (§16.3) for punching
  one window fully in/out of the effect. *Reads as cinematic focus; "the OS composes around
  what you're doing."*
- **Keyboard-reactive (win, toggle, preset-scoped).** Stylized responses to typing, applied
  **only where it serves the world** so a calm preset never gets cluttered: Matrix glyphs
  spawn on keystrokes, CRT/VHS a faint phosphor flicker per key, Cyberpunk a tiny keystroke
  glitch. Reading / Studio / Crisp Text and the artistic worlds stay silent. A global
  key-event monitor needs the **Input Monitoring** permission — a TCC prompt of the same
  class as Screen Recording, and the one new permission this build introduces; gate the
  feature on it and degrade gracefully when denied. Per-world opt-in via `WorldSpec`. Files:
  `PointerInputSampler` (add a guarded key monitor) → `FrameContext.keyAge` / `keyChar`, new
  `fx_int_keyGlyph` etc. in `Interaction.metal`.

(Time-of-day drift dropped per owner.)

### 15.2 Geometry-aware generative content (win → roadmap)

The defining "engine, not filter" move: ambient elements that **know the UI**. The particle
shaders (rain, bubbles, dust) read the §5.1 window-rect buffer to collide and occlude — rain
that lands on and is hidden behind window tops, bubbles that nestle against window edges, film
dust that pools in the gaps (e.g. Golden Hour dust motes drifting in the light and settling
on window tops). Later (roadmap): a per-world **living desktop** painted only in the window
gaps via the existing adaptive-tint overlay infra — Matrix rain and Cyberpunk neon rain on
the wallpaper, Frutiger water caustics + rising bubbles behind your windows. *This is the
clearest separation from "a LUT on a screenshot."*

### 15.3 Context routing — world automation (roadmap)

A small rules engine mapping **context → world**, applied through the atomic preset-switch
(§8): per-app (Matrix in Terminal, Golden Hour in Photos — via
`NSWorkspace.frontmostApplication.bundleIdentifier`, public), per-Space (the existing
SkyLight Space id), and schedule (Night Light at sunset, Studio 9–5). No AX. New
`Sources/Engine/WorldRouter.swift` + a rules UI. *"It knows where you are" — the feature that
makes it a daily driver instead of a toy.*

### 15.4 Styled output — shareability (mostly shipped → roadmap)

Spectra already ships a **"Show in Screenshots"** toggle
([StudioView.swift:188](../Sources/UI/Studio/StudioView.swift) →
`RenderEngine.setOverlaysVisibleToScreenshots`) that flips the overlay's capture exclusion, so
the styled desktop can be screenshotted and screen-recorded with the **native macOS tools**
today. That already covers most of the shareability need. Remaining, optional:
- **One-press in-app capture (small win).** A hotkey that writes the final composited frame
  (or a short clip) straight to a file, skipping the toggle + native-tool dance. Trivial given
  the final texture already exists; pure convenience.
- **Virtual camera (roadmap).** A CoreMediaIO system extension that publishes the styled
  desktop as a camera into Zoom / OBS / Meet — the one genuine gap (live streaming) and the
  larger lift (a separate notarized extension).

Files: a `Sources/Render/StyledOutput.swift` tap off `DisplayRenderer`'s final texture.
*The screenshot path already works; the camera is the streaming flywheel.*

### 15.5 World sharing (exporter exists → extend, then gallery)

Spectra **already** exports and imports presets/effects: `StudioView` has a `.fileExporter`
for presets / shaders / composites, `CustomShader` is a versioned exportable `.spectra` / JSON
container, and `ShaderImporter` ingests `.metal` / `.shader` / `.json` / `.spectra` from a
watched folder. The plumbing is done. The only work to make a **world** shareable is ensuring
the new `WorldSpec` facets (cursor, system-UI, motion) serialize into that export and
re-apply on import (win, small). A community gallery / one-click install is the later growth
play (roadmap). *User-generated worlds are free content and free marketing.*

---

## 16. Interface: radical simplification & control (Phase 4 — Polish)

The engine will be powerful; the product must feel effortless. Today the surface is a
pro-tool: a Studio workspace plus a composer, a 151-effect library, an inspector, a stack
editor, a performance view, a preview, four settings screens, and a menu-bar panel. Almost
everyone wants one thing — **pick a world.** This phase reorganizes around that, Jobs-style:
say no to surface, hide complexity behind one door, make the default path understandable in
five seconds.

### 16.1 Principles
- **One primary action per screen.** The main window is a world gallery; you pick, it applies.
- **Progressive disclosure, not removal.** All the power stays, behind a single "Studio
  (advanced)" door, not in your face.
- **Great defaults.** Every world ships dialed-in; the median user never opens Advanced.
- **Human words.** "Worlds," not "preset chains"; "intensity," not "universal strength."
- **Ruthless reduction** of chrome, labels, toggles, and nesting on the everyday path.

### 16.2 Concrete moves
- **Two modes, one switch.** Default **Worlds**: a full-bleed gallery of the worlds + a single
  master **Intensity** + an on/off. Advanced **Studio**: the existing composer / library /
  stack / inspector / performance, unchanged, behind one button. Demote those panels out of
  the default window entirely — [ComposerView](../Sources/UI/Composer/ComposerView.swift),
  [EffectLibraryView](../Sources/UI/Effects/EffectLibraryView.swift),
  [InspectorView](../Sources/UI/Inspector/InspectorView.swift),
  [EffectStackView](../Sources/UI/Stack/EffectStackView.swift),
  [PerformanceView](../Sources/UI/Performance/PerformanceView.swift) live in Studio mode only.
- **Settings to one short pane.** Permission, cursor, the audio / focus / keyboard toggles,
  and hotkeys. Fold [LicenseView](../Sources/UI/Settings/LicenseView.swift),
  [SIPRequiredView](../Sources/UI/Settings/SIPRequiredView.swift), and
  [SystemAccessibility](../Sources/UI/Settings/SystemAccessibility.swift) into a collapsible
  "System / Advanced" area.
- **Menu-bar extra = the quick switcher.** Worlds grid + intensity + off, always one click
  away; [MenuBarView](../Sources/UI/MenuBar/MenuBarView.swift) is most of the way there.
- **One visual language.** Consolidate on [Theme.swift](../Sources/UI/Theme/Theme.swift); kill
  one-off styling.

### 16.3 Control features (assignable, no AX)
Both ride the existing Carbon [GlobalHotKey](../Sources/App/GlobalHotKey.swift) (no
Accessibility permission), with a small key-recorder in Settings:
- **Hotkey world-switcher.** User-assignable bindings to cycle worlds, jump to a specific
  world, and toggle Spectra on/off.
- **Filter active window in/out.** A hotkey that punches the focused window's rect (from the
  §5.1 geometry feed) out of the effect — showing the true desktop there — or restricts the
  effect to it. The manual counterpart to focus spotlight (§15.1), for "I need to read this
  one thing clearly." Implemented as a mask uniform over the focused rect in the chain; no AX.

### 16.4 Onboarding
- First run is **one guided flow**: grant Screen Recording → pick a world → done. Trim
  [WelcomeView](../Sources/UI/Studio/WelcomeView.swift) to that.
- Teach the two control hotkeys and the Show-in-Screenshots capture in a single dismissible
  tip, not a tour.
