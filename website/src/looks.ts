// The captured looks: real before/after screenshots of everyday apps run through
// Spectra's presets. Each entry has a matched -before / -after WebP in
// public/looks/. `slug` is the file stem; `preset` is the look actually applied.

export interface Look {
  slug: string;   // public/looks/<slug>-{before,after}.webp
  preset: string;
  app: string;
  line: string;   // one short factual line
}

// Painting leads as the big seller (the full desktop), then CRT and Golden Hour,
// then the rest. Order is the scroll order.
export const HERO: Look = {
  slug: "painting", preset: "Painting", app: "the desktop",
  line: "Impressionist oil and a luminous watercolour wash, over everything at once.",
};

export const LOOKS: Look[] = [
  { slug: "studio",   preset: "CRT Display",   app: "VS Code",     line: "The glow and grain of a phosphor tube: scanlines, mask, persistence." },
  { slug: "reading",  preset: "Golden Hour",   app: "Claude",      line: "Warm halation bloom, the whole screen lit like late afternoon." },
  { slug: "frutiger", preset: "Frutiger Aero", app: "Spotify",     line: "Lush nature-tech glass: aqua-greens and glossy bubble bloom." },
  { slug: "matrix",   preset: "The Matrix",    app: "VS Code",     line: "A live terminal: code rain over a near-mono green-black world." },
  { slug: "noir",     preset: "Noir",          app: "YouTube",     line: "Darkroom black-and-white built on real film colour science." },
  { slug: "print",    preset: "Pencil Sketch", app: "Google Docs", line: "Graphite contours and cross-hatch shading on warm paper." },
  { slug: "cool",     preset: "Print Art",     app: "Finder",      line: "Woodblock print: flat colour fields and crisp key-block lines." },
];
