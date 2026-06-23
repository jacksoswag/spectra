# Spectra website

The marketing site for Spectra. A static, single-page build with no framework and
no live engine: the proof is real before/after captures of everyday apps run
through the presets, presented as an editorial sequence of full-bleed
drag-to-compare reveals.

## Structure

- **`src/main.ts`** mounts the page and wires the scroll reveal.
- **`src/ui/page.ts`** builds every section with a tiny `h()` element helper
  (`src/ui/dom.ts`). No framework.
- **`src/ui/compare.ts`** is the before/after drag slider (pointer drag plus a
  keyboard range input, one CSS custom property; `fill` mode for the full-bleed
  hero).
- **`src/looks.ts`** lists the captured looks; each has a matched
  `-before` / `-after` WebP in `public/looks/`.
- **`src/presets.ts`** mirrors the 16 presets from
  `Sources/Presets/BuiltInPresets.swift` for the catalogue.
- **`src/styles.css`** is the whole design system: dark instrument chrome, the
  prism spectrum used only as a brand signature, one cyan accent.

## Assets

`public/looks/` holds web-optimised WebP exported from the full-res desktop
captures. To regenerate from new screenshots:

```sh
ffmpeg -i shot.png -vf "scale=1600:-1:flags=lanczos" -c:v libwebp -quality 82 out.webp
```

before/after pairs share the same capture geometry, so they align in the slider
without extra cropping.

## Develop

```sh
npm install
npm run dev      # http://localhost:5173
```

## Build and deploy

```sh
npm run build    # type-checks, then writes dist/
npm run preview
```

`dist/` is a static folder with no server requirement. Point Vercel, Netlify,
Cloudflare Pages, or GitHub Pages at it. Update the `og:image` host once the
domain is live.

## Brand

- **Mark**: a prism splitting a white beam into the spectrum.
- **Tagline**: "Your whole desktop, shaded."
- **Palette**: near-black graphite base; the screenshots carry the colour. The
  spectral accent (magenta `#ff3df0`, violet `#8b5cff`, cyan `#2fd9ff`, lime
  `#b6ff3d`) appears only on the mark, the word "shaded", and the primary button.
  Interactive state uses a single cyan `#38e0ff`.
- **Type**: Space Grotesk (display), Inter (body), a mono stack for figures.
