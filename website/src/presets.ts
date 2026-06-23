// Preset metadata for the landing page, mirrored from
// Sources/Presets/BuiltInPresets.swift. Used by the preset catalogue. The
// imagery on the page comes from real captures in src/looks.ts, not from here.

export type PresetCategory = "Cinematic" | "Retro" | "Artistic" | "Utility";

export interface Preset {
  key: string;
  name: string;
  category: PresetCategory;
  summary: string;
}

export const PRESETS: Preset[] = [
  { key: "golden", name: "Golden Hour", category: "Cinematic", summary: "Warm halation glow and golden-hour bloom across the whole desktop." },
  { key: "fuji", name: "Fuji-Film", category: "Cinematic", summary: "Warm 2000s disposable-camera look: an amber flash-lit cast, punchy contrast, and heavy live colour grain." },
  { key: "noir", name: "Noir", category: "Cinematic", summary: "Darkroom-accurate black-and-white built on real film colour science." },
  { key: "cyberpunk", name: "Cyberpunk", category: "Cinematic", summary: "Your desktop as a neon-lit night city: crushed blacks and blooming magenta-cyan light." },

  { key: "crt", name: "CRT Display", category: "Retro", summary: "The glow and grain of a real phosphor tube: scanlines, shadow mask, and temporal persistence." },
  { key: "vhs", name: "VHS Tape", category: "Retro", summary: "Magnetic-tape decay running live: warm chroma bleed, tracking drift, and tape hiss." },
  { key: "matrix", name: "The Matrix", category: "Retro", summary: "A live hacker terminal: animated code rain over a near-mono green-black world." },
  { key: "frutiger", name: "Frutiger Aero", category: "Retro", summary: "Lush nature-tech glass: vivid aqua-greens, clean skies, and glossy bubble bloom." },

  { key: "painting", name: "Painting", category: "Artistic", summary: "Soft painted desktop: impressionist oil brushwork finished with a luminous watercolor wash." },
  { key: "comic", name: "Comic Book", category: "Artistic", summary: "Pop-art print: punchy flat posterized colour and a Ben-Day halftone dot screen." },
  { key: "print", name: "Print Art", category: "Artistic", summary: "Woodblock print: flat colour fields, crisp key-block lines, and visible washi paper." },
  { key: "pencil", name: "Pencil Sketch", category: "Artistic", summary: "A hand-drawn graphite sketch: contour lines, cross-hatch shading, and warm paper." },

  { key: "studio", name: "Studio", category: "Utility", summary: "A calibrated display upgrade: deeper blacks, richer midtones, and crisp clarity, all day." },
  { key: "reading", name: "Reading", category: "Utility", summary: "Paper-white for your whole screen: reduced dark-UI glare and softened peak white." },
  { key: "night", name: "Night Light", category: "Utility", summary: "Warm, blue-light-reduced screen for late-night use with a gently dimmed white point." },
  { key: "crisp", name: "Crisp Text", category: "Utility", summary: "Razor-sharp UI text: edge sharpening plus midtone clarity with no colour change." },
];
