# Architecture

Spectra is organized into focused modules under `Sources/`. Each module owns one concern and exposes a small surface. A single `SpectraEngine` coordinator composes them and is the only object the UI observes. Dependencies are injected, not reached for through globals.

## Modules

| Module | Path | Responsibility |
| --- | --- | --- |
| Core | `Sources/Core` | The data model: parameters, effect descriptors, effect instances, the effect stack, blend modes, logging. No Metal, no UI. |
| Capture | `Sources/Capture` | Display enumeration, screen-recording permission, and per-display ScreenCaptureKit streaming to zero-copy Metal textures. |
| Render | `Sources/Render` | The Metal pipeline: GPU context, pipeline cache, texture pool, the chain renderer, per-display renderers, and the click-through overlay windows. |
| Effects | `Sources/Effects` | The effect registry and the descriptors for all 158 built-in effects, organized by category. |
| Shaders | `Sources/Shaders` | The Metal source: a shared header plus one file per category. |
| Presets | `Sources/Presets` | The preset model, the user/built-in libraries, recents, and persistence. |
| Storage | `Sources/Storage` | Paths, JSON persistence, settings, the versioned `.spectra` document format, and the file importer. |
| Performance | `Sources/Performance` | Frame sampling, rolling statistics, the live snapshot, adaptive quality, and the on-demand per-effect GPU profiler. |
| Editor | `Sources/Editor` | Runtime shader compilation and diagnostics, the imported-shader store, the visually-composed-effect store, thumbnail rendering, the prelude, and the library folder watcher. |
| Engine | `Sources/Engine` | The `SpectraEngine` coordinator and the chain resolver (which expands composed effects and bakes texture-backed parameters). |
| UI | `Sources/UI` | The single unified SwiftUI workspace, the visual composer, panels, controls, preview, and menu bar. |
| App | `Sources/App` | Entry point and app delegate. |

## The effect contract

Effects are data-driven. An effect is an `EffectDescriptor`: an id, a category, a list of `EffectParameter` definitions, and one or more GPU passes. The renderer is generic over descriptors, so adding an effect means adding a descriptor and a matching Metal function. Nothing in the renderer changes.

Parameters and the GPU agree on a flat layout. Each parameter occupies a run of slots in a 64-float array (a scalar takes one slot, a point takes two, a color takes four), assigned in declaration order. The shader reads `u.params[i]` in that same order. This is the binding between a descriptor and its function.

Every Metal effect function has the same signature:

```metal
fragment float4 fx_name(RasterizerData in [[stage_in]],
                        texture2d<float> src [[texture(0)]],   // sampling source
                        texture2d<float> orig [[texture(1)]],  // original input, for compositing
                        constant SpectraUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(orig, in.uv).rgb;
    float3 c = spectra_tex(src, in.uv).rgb;
    // ... compute processed ...
    return spectra_compositeRGBA(base, processed, u);
}
```

`spectra_composite` applies the universal parameters (blend mode and amount, then strength times opacity) so every effect gets strength, opacity, blend amount, and one of the 16 blend modes without writing that code each time. The shared header `SpectraCommon.h` also provides the uniform struct, sampling helpers, color-space conversions, a procedural noise library (value, gradient, simplex, cellular, gaussian, fbm), and the blend operators. The CPU mirror of the uniform struct lives in `Uniforms.swift`; both sides agree on a flat 80-float layout so uploading the buffer is layout-safe.

Beyond the flat uniforms, two extra binding channels exist. **Auxiliary textures** (bound at fragment texture index 2 and up) realise parameters that don't fit uniforms: a tone curve bakes to a 256×1 lookup, a gradient to a 256×1 RGBA strip, and a color LUT to a 33³ 3D texture. `AuxTextureFactory` generates these at resolve time from the parameter values; the resolver attaches them to the `ResolvedEffect` in parameter-declaration order. A **history texture** (index 10) holds the previous frame's processed output for feedback effects (datamosh, frame repeat/skip, phosphor persistence); descriptors that need it set `needsHistory`, and the per-display renderer maintains the feedback texture only when the chain uses one. A pass may also **tap an earlier pass's output** (bound at index 9 via `EffectPass.tapPass`): the renderer keeps that intermediate alive instead of recycling it, so a late pass can reuse a result rather than recompute it (the oil paint combine reuses the smoothed structure tensor the blur passes built). A pass can also drive its render scale from a parameter slot (`EffectPass.scaleParam`) for a runtime quality control.

**Composed effects** are authored in the visual composer and stored as an ordered list of building-block stages plus the parameters the author exposed. They register as placeholder library descriptors; the chain resolver expands each into its component passes, applying exposed-parameter overrides and folding in the composite's strength and opacity. Imported raw `.metal`/`.shader` files become single-function custom effects. Both kinds appear in the library alongside the built-ins.

## The render pipeline

For each captured frame on each enabled display:

1. **Capture.** A `CaptureSession` receives a `CMSampleBuffer` from ScreenCaptureKit, wraps its `IOSurface`-backed pixel buffer as an `MTLTexture` through a `CVMetalTextureCache`, and delivers it on the capture queue. No copy.
2. **Resolve.** The engine turns the editable `EffectChain` into render-ready `[ResolvedEffect]` once per change, dropping disabled and unknown effects and attaching the custom library for authored shaders.
3. **Encode.** `EffectChainRenderer` walks the resolved chain, ping-ponging textures from a pool. Each pass binds its source on texture 0, the effect's original input on texture 1, and a packed uniform buffer, then draws a full-screen triangle. Separable effects like Gaussian blur declare multiple passes with a direction vector.
4. **Present.** The final texture is drawn onto the overlay window's `CAMetalLayer`, a display-synced 16-bit-float extended-range layer with EDR enabled on capable displays, so bright effect output maps to real HDR luminance. Intermediate textures return to the pool on GPU completion. The command buffer's status is checked on completion; a GPU fault is surfaced so the coordinator can disable the offending effect.

Rendering runs on the capture delivery queue for low latency, gated by a triple-buffer semaphore. A frame with no free slot is dropped and counted rather than queued.

## The overlay model

Each display gets a borderless, click-through `OverlayWindow` hosting a `CAMetalLayer`, placed above ordinary application windows. The Studio window sits above the overlay and is excluded from capture along with the overlay itself, so the control surface stays crisp and the capture never sees Spectra's own pixels. Clicks pass through the overlay to the real desktop beneath.

## State and concurrency

- Observable models use the Observation framework and live on the main actor.
- The editable `EffectStack` is the single source of truth. Every mutation goes through a method that notifies the engine, which re-resolves and pushes an immutable snapshot to the renderer.
- The renderer reads chain snapshots under a lock from the capture queue, so the UI can edit freely while frames are in flight.
- Performance samples are recorded lock-protected from GPU completion handlers and aggregated for the UI on a timer, decoupling UI updates from the frame rate.

## Persistence

- Settings, per-display chains, per-display active presets, and recents are JSON under `~/Library/Application Support/Spectra`.
- User presets are individual JSON files in the presets directory.
- Imported/authored custom shaders are saved as `.spectra` documents in the shaders directory; composed effects are saved in the effects directory. Both are recompiled/re-registered on launch.
- The library folder is watched: dropping a `.metal`, `.shader`, or `.spectra` file imports and hot-reloads it without a relaunch.
- Imported `.metal` and `.shader` files are compiled against the prelude and validated before registration; a file that fails to compile reports diagnostics and is never handed to the renderer. The `.spectra` document is versioned with provenance metadata and decodes tolerantly across versions.
