import { defineConfig } from "vite";

// Static, single-page marketing site. No SSR, no framework — the whole page is a
// live WebGL2 surface, so everything is client-side anyway. Point any static host
// (Vercel / Netlify / Cloudflare Pages / GitHub Pages) at the built `dist/`.
export default defineConfig({
  base: "./",
  build: {
    target: "es2022",
    assetsInlineLimit: 0,
  },
});
