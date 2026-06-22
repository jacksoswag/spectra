# Spectra website

A single-frame, looping **cinematic** in the spirit of Alan Becker's "Animator vs.
Animation": two stick figures — a cyan hero and a greedy magenta rival — fight over a
prism that re-shades the whole desktop. Each time it changes hands the surface morphs to
a different real app (macOS desktop, Spotify, YouTube, Google Docs, Terminal, Photos,
Figma) and re-shades into the preset that fits it. The presets are WebGL ports of the
app's real shaders, so the page is literally a desktop being shaded in real time. The
marketing facts are delivered through the scene as it loops. Vanilla, zero dependencies.

## Preview

```sh
cd website
python3 -m http.server     # then open the printed URL
```

## Structure

- `index.html` / `css/cinematic.css` — the shaded stage, the character overlay canvas,
  and the floating UI (brand, CTA, subtitle, fact chip, play/pause · 2× · scrubber).
- `js/shaders.js` — the 16 real preset worlds (faithful to
  `Sources/Presets/BuiltInPresets.swift`) plus the prism-beam transition. One source of
  truth for the shaders.
- `js/engine.js` — WebGL: uploads a 2D scene, shades it through the current preset, and
  fires the radial colour beam on a switch.
- `js/rig.js` — the stick-figure skeleton, a named pose library, and keyframe
  interpolation with a dark contour pass for legibility over any shader.
- `js/scenes.js` — `SceneKit` chrome helpers + each app surface's `draw(x, t, W, H)`.
- `js/story.js` — the 13-shot timeline: per shot a scene + preset + duration + the
  cyan/magenta keyframes + prop flags (wall, POW, paused bar, blinds, magnifier, fade).
- `js/cinematic.js` — the director: the clock, play/pause, 2× speed, scrubber, the orb,
  the props, and the UI.
- `assets/` — `logo.svg`, `favicon.svg`, `icon.svg` (app-icon art), `og.svg` (social card).

## Editing the sequence

The whole loop is data. To re-choreograph, edit the `SHOTS` array in `js/story.js` (each
shot's `scene`, `preset`, `dur`, and the `cyan`/`magenta` keyframes built from the poses
in `js/rig.js`). Add an app surface by adding a `draw()` to `js/scenes.js`. Add a look by
adding a shader to `js/shaders.js` that mirrors the matching Swift preset.

## Deploy

Plain static folder, no build step. Point Vercel / Netlify / Cloudflare Pages / GitHub
Pages at `website/`. Update the `og:image` host once the domain is live.

## Brand

- **Name / mark**: Spectra — a prism splitting a white beam into the spectrum.
- **Tagline**: "Your whole desktop, shaded."
- **Palette**: near-black base; spectral accent magenta `#ff3df0` → violet `#8b5cff` →
  cyan `#2fd9ff` → lime `#b6ff3d`. **Type**: Space Grotesk (display) + Inter (body).

## Assets that need converting

The brand art is SVG (source). Two outputs need raster/native formats:

- **App icon** — convert `assets/icon.svg` to the `.icns` set (`AppIcon.appiconset`):
  render PNGs at 16…1024 with `rsvg-convert`/`sips`, then `iconutil -c icns`.
- **Social image** — render `assets/og.svg` to a 1200×630 PNG and point `og:image` at it
  once hosted (some platforms require a raster card).
