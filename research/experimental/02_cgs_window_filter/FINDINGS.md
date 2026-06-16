# Test 2 — CGS / SkyLight per-window Core Image filter path (EMPIRICAL)

**Machine:** MacBook Air M3, macOS 26.5.1 (25F80), SIP off. Symbols resolved via dlsym
from CoreGraphics (all present; CoreGraphics re-exports SkyLight). Verification by
`screencapture` (claude-code holds Screen Recording TCC) + `findings/imgstat` pixel reads.

**Verdict: the programmable per-window CIFilter path is DEAD on Tahoe.**
Only the dedicated fixed-blur SPI (`CGSSetWindowBackgroundBlurRadius`) still works.

## What was run

`cgsfilter.m` — renders a high-contrast test card (left RED, right BLUE, green circles,
B/W checkerboard) in a window, then applies a filter via the CGS path and stays up for capture.

## Results

### 1. `CGSNewCIFilterByName` rejects almost everything — `kCGErrorNotImplemented` (1006)

24 filter names tested. Exactly ONE is accepted:

| Filter name | `CGSNewCIFilterByName` result |
|---|---|
| **CIColorInvert** | **CGError=0 (accepted)** |
| CIGaussianBlur, CIBoxBlur, CIDiscBlur | 1006 NotImplemented |
| CIPixellate, CICrystallize | 1006 |
| CITwirlDistortion, CIBumpDistortion | 1006 |
| CIColorControls, CIColorMatrix, CIHueAdjust, CIExposureAdjust, CISepiaTone, CIColorMonochrome, CIFalseColor, CIVibrance, CIPhotoEffectMono, CIColorClamp, CIColorPosterize, CIGammaAdjust, CIColorCrossPolynomial, CITemperatureAndTint, CIWhitePointAdjust, CIVignette | 1006 |
| CIColorInvertXYZ (bogus control name) | 1006 |

The bogus name also returns 1006, so this is a genuine server-side allowlist of one
name, not "any string returns success." Even `CIGaussianBlur` — which historically worked
through this API — is now rejected at creation.

### 2. The one accepted filter, CIColorInvert, is a SILENT NO-OP

`CGSAddWindowFilter` returns `CGError=0` for flags 0, 1, and 0x3001 (12289), but the
composited pixels are unchanged. Pixel reads of the window region, baseline vs filter:

```
BASELINE       left cell #D12011 (red)   right cell #0C2CD4 (blue)   avg #6A346F
CIColorInvert  left cell #D12011 (red)   right cell #0C2CD4 (blue)   avg #69346F   (identical)
```

If invert worked, red→cyan (#00FFFF) and blue→yellow (#FFFF00). It does not. Confirmed for:
- opaque window, flag=1 (underlay) and flag=0x3001 (dock): no change
- Tranquility-style translucent overlay over the red/blue backdrop, flag=1 and 0x3001:
  the backdrop seen under the overlay is NOT inverted.

`CGError=0` here is a lie — the call is accepted and dropped. (This is why API return
codes alone are insufficient; visual capture was required.)

### 3. Custom CIFilters cannot work (as predicted)

A filter name registered only in this process (`SpectraCustomInvertKernel`) returns 1006:
`CGSNewCIFilterByName` instantiates the filter inside the WindowServer process, which has
no knowledge of an in-process CIFilter/CIKernel. There is no path to ship custom shader
code into the compositor this way.

### 4. `CGSSetWindowBackgroundBlurRadius` is ALIVE and genuinely functional

Returns `CGError=0` AND actually blurs. Edge-sharpness probe across the red|blue boundary
of a backdrop seen through a translucent overlay:

```
BASELINE (sharp):   ...CF1F0D CF1F0D | 0729D2 0729D2...   (abrupt red->blue)
WITH blur(30):      ...BC330E BA3411 B7321A AF2E2B 9E2945 852666 642886 432D9F 2933AE 1837B5 0F39B9 0D39BA...  (smooth red->purple->blue, circles smeared)
```

This is a fixed Gaussian blur of content behind your OWN window. It is the same SPI WezTerm
uses (PR #3344) and the only surviving CGS visual effect. It is NOT programmable (just a
radius) and only affects content behind windows you own.

## Implications for Spectra

- The CGS window-filter path is **not** a usable route for per-window shaders. Dead end,
  confirmed on the current OS. ScreenCaptureKit → Metal → overlay remains the only way.
- `CGSSetWindowBackgroundBlurRadius` is the one freebie: a real, cheap, server-side
  background blur Spectra could use on its OWN Studio/overlay chrome (vibrancy), nothing more.
- No WindowServer crashes occurred during ~40 filter attach/detach cycles. The path is
  inert, not unstable.

## Error code reference
`1006 = kCGErrorNotImplemented` (from the macOS 26 SDK `CGError.h`).
