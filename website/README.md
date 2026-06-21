# Spectra website

The marketing site for Spectra. A static, zero-dependency page (vanilla HTML, CSS,
and JS). Its entire background is a **live WebGL renderer**: a mock macOS desktop
re-shaded through all 16 of the app's real preset worlds, auto-cycling "best first"
with a prism-dispersion transition between each. Content rides on frosted glass so the
shading shows through. Because the app's overlay can't be screen-captured, the page
itself is the demo — it is literally a desktop being shaded in real time.

All copy (world names, descriptions, the 169-effect / 14-category counts, the free
tier) is lifted from the Swift source so the site can't drift from the app.

## Preview

```sh
cd website
python3 -m http.server 8000     # then open http://localhost:8000
```

Or just open `index.html` in a browser.

## Deploy

It's a plain static folder, so any static host works. Point the host at the
`website/` directory (no build step):

- **Vercel / Netlify / Cloudflare Pages**: drag the folder in, or set the project root
  to `website/`. No build command, output dir = `.`.
- **GitHub Pages**: serve `website/` from a branch.

Set the domain's apex/`www` to it. Update the footer links and `og:image` host once
the domain is live.

## Structure

- `index.html` — markup and sections (hero + now-playing HUD + world deck, worlds,
  effects, how-it-works, pricing, FAQ).
- `css/style.css` — the brand system, the glass panels, the HUD, and the world deck.
- `js/demo.js` — the renderer: a mock macOS desktop drawn to a texture, 16 fragment
  shaders faithful to `Sources/Presets/BuiltInPresets.swift`, and a two-FBO composite
  that does the prism-dispersion sweep between worlds. Exposes `window.Spectra`
  (`transitionTo`, `setAmount`, `current`, `busy`).
- `js/site.js` — the 16-world data (verbatim copy), the deck, the now-playing HUD, the
  auto-cycle, the 14-category grid, and scroll reveals.
- `assets/` — `logo.svg`, `favicon.svg`, `icon.svg` (app-icon art), `og.svg` (social card).

## Brand

- **Name / mark**: Spectra. A prism splitting a white beam into the spectrum.
- **Tagline**: "Your whole desktop, shaded."
- **Palette**: near-black `#07060e` base; spectral accent
  magenta `#ff3df0` → violet `#8b5cff` → cyan `#2fd9ff` → lime `#b6ff3d`.
- **Type**: Space Grotesk (display) + Inter (body), via Google Fonts.

## Assets that need converting

The brand art is SVG (source). Two outputs need raster/native formats:

- **App icon** — convert `assets/icon.svg` to the `.icns` set for the app
  (`AppIcon.appiconset`). For example, render PNGs at 16…1024 with
  `rsvg-convert`/`sips`, then `iconutil -c icns`. (The current build still uses the
  existing `AppIcon`; swap it in when ready.)
- **DMG background** — `../branding/dmg-background.svg` must be a PNG (Finder doesn't
  render SVG): e.g. `rsvg-convert -w 640 -h 400 branding/dmg-background.svg -o branding/dmg-background.png`
  (plus an `@2x`). Wiring it into `Scripts/release.sh` needs a Finder window-layout
  step; the plain DMG ships fine without it.

## Social image

`assets/og.svg` is the share card. Some platforms want a raster `og:image`; render it
to a 1200×630 PNG and point `og:image` at that URL once hosted.
