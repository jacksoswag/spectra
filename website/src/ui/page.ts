// The Spectra landing, built as an editorial sequence of full-bleed before/after
// reveals. Real desktop captures dominate; the chrome nearly disappears. Drag any
// image to grade it. Copy stays direct and sparse, no em-dashes, no hype.

import { h } from "./dom";
import { compare } from "./compare";
import { PRESETS, type PresetCategory } from "../presets";
import { HERO, LOOKS } from "../looks";

const CATEGORY_ORDER: PresetCategory[] = ["Cinematic", "Retro", "Artistic", "Utility"];
const BUY = "Get Spectra";
const PRICE = "$9.99";
// Lemon Squeezy checkout (Merchant of Record). Set before launch; "#" no-ops the link until then.
const BUY_URL = "https://spect-crow.lemonsqueezy.com/checkout/buy/e9a63740-558f-4cea-adf2-bf94134d3bec";

export function buildPage(): DocumentFragment {
  const frag = document.createDocumentFragment();
  frag.append(
    h("a", { class: "skip-link", href: "#looks" }, "Skip to content"),
    nav(),
    h("main", {}, hero(), looks(), instrument(), catalog(), hardware(), close()),
    footer(),
  );
  return frag;
}

// ---- nav: wordmark + one action ----
function nav(): HTMLElement {
  return h("header", { class: "nav" },
    h("a", { class: "nav__brand", href: "#top", "aria-label": "Spectra home" }, prismMark(), h("b", {}, "Spectra")),
    h("a", { class: "btn", href: BUY_URL }, `${BUY} · ${PRICE}`),
  );
}

// ---- hero: full-bleed Painting reveal, title laid over it ----
function hero(): HTMLElement {
  return h("section", { id: "top", class: "hero" },
    compare({ before: img(HERO.slug, "before"), after: img(HERO.slug, "after"), app: HERO.app, preset: HERO.preset, start: 50, eager: true, fill: true }),
    h("div", { class: "hero__scrim" }),
    h("div", { class: "hero__title" },
      h("h1", {}, "Your whole desktop, ", h("span", { class: "grad" }, "shaded"), "."),
      h("p", { class: "hero__sub" }, "A GPU between you and your screen, grading every display in real time. Drag the line."),
      h("a", { class: "btn btn--lg", href: "#buy" }, `${BUY} · ${PRICE}`)),
  );
}

// ---- looks: the sequence of reveals ----
function looks(): HTMLElement {
  const items = LOOKS.map((l, i) =>
    h("figure", { class: "look" + (i % 2 ? " look--alt" : "") },
      h("figcaption", { class: "look__cap" },
        h("h2", {}, l.preset),
        h("p", {}, h("span", { class: "look__app" }, l.app), " ", l.line)),
      h("div", { class: "look__media" },
        compare({ before: img(l.slug, "before"), after: img(l.slug, "after"), app: l.app, preset: l.preset, start: 50 }))),
  );
  const note = h("p", { class: "looks__note" },
    "Drag any image to compare. These are still frames. Live, most presets are in motion: grain crawls, scanlines roll, code rains, glass ripples.");
  return h("section", { id: "looks", class: "looks" }, note, glassLead(), ...items);
}

// Liquid Glass leads the sequence. It is the system preset, set apart from the
// sixteen, shown as a real before/after of the whole desktop turning to glass,
// with a short overview above the reveal.
function glassLead(): HTMLElement {
  return h("figure", { id: "glass", class: "look look--lead" },
    h("figcaption", { class: "look__cap" },
      h("p", { class: "eyebrow" }, "The system preset"),
      h("h2", {}, "Liquid Glass"),
      h("p", { class: "look__overview" },
        "Set apart from the sixteen, Glass reshapes the desktop itself instead of grading the image. Windows turn translucent so your wallpaper reads straight through them, tile themselves into place, and take on an adaptive tint pulled from that wallpaper. Drag to send every window to glass.")),
    h("div", { class: "look__media" },
      compare({ before: img("glass", "before"), after: img("glass", "after"), app: "the desktop", preset: "Liquid Glass", start: 50 })));
}

// ---- instrument: how it works, quietly ----
function instrument(): HTMLElement {
  const figures: [string, string][] = [
    ["209", "real-time effects"], ["16", "presets"], ["Every display", "native resolution and refresh"],
  ];
  return h("section", { id: "engine", class: "wrap engine" },
    h("h2", { class: "engine__lead" }, "It is a real GPU between you and your screen."),
    h("p", { class: "prose" },
      "ScreenCaptureKit feeds every connected display into Metal at native resolution and refresh. Frames never touch the CPU. The graded result renders through a click-through overlay that follows you across Spaces and shades full-screen apps. One menu-bar item, not a mode you enter."),
    h("dl", { class: "figs" },
      ...figures.map(([n, l]) => h("div", {}, h("dt", {}, n), h("dd", {}, l)))),
  );
}

// ---- catalog: the full sixteen, as an index ----
function catalog(): HTMLElement {
  const fams = CATEGORY_ORDER.map((cat) =>
    h("div", { class: "fam" },
      h("h3", { class: "fam__name" }, cat),
      ...PRESETS.filter((p) => p.category === cat).map((p) =>
        h("div", { class: "fam__row" }, h("b", {}, p.name), h("span", {}, p.summary)))),
  );
  return h("section", { id: "presets", class: "wrap catalog" },
    h("h2", { class: "catalog__lead" }, "Sixteen presets. Four families. Or build your own."),
    h("p", { class: "prose" },
      "Each is a stack of real effects you switch from the menu bar. Compose your own in the visual editor, or drop a Metal shader in the folder and it hot-reloads."),
    h("div", { class: "fams" }, ...fams),
  );
}

// ---- close ----
function close(): HTMLElement {
  return h("section", { id: "buy", class: "wrap close" },
    h("h2", { class: "close__price" }, "Nine ninety-nine. ", h("span", { class: "grad" }, "Once"), "."),
    h("p", { class: "prose close__prose" },
      "Buy it once and the full app unlocks. A free tier ships the cinematic presets, so you can run a shaded desktop before you pay anything. macOS 15 or later, Apple Silicon."),
    h("a", { class: "btn btn--lg", href: BUY_URL }, `${BUY} · ${PRICE}`),
  );
}

// ---- hardware: what runs it at native resolution ----
// Minimum = holds a mid-weight preset (Cyberpunk) at native 60fps; Recommended =
// holds the heaviest preset (Frutiger Aero) at native 60fps. Both at full
// resolution, no quality scaling. Verdicts measured per chip across the lineup.
function hardware(): HTMLElement {
  const rows: [string, boolean, boolean][] = [
    ["MacBook Air (M1–M4)", true, false],
    ['MacBook Pro 14"/16" (M3 / M4)', true, true],
    ['iMac 24" (M1 / M3)', false, false],
    ['iMac 24" (M4)', true, false],
    ["Mac mini (M4)", true, false],
    ["Mac mini (M4 Pro)", true, true],
    ["Mac Studio (M4 Max / M3 Ultra)", true, true],
    ["Mac Pro (M2 Ultra)", true, true],
  ];
  return h("section", { id: "hardware", class: "wrap hardware" },
    h("h2", { class: "catalog__lead" }, "What runs it."),
    h("p", { class: "prose" },
      "Every display is graded at its native resolution, never upscaled. Minimum holds the mid-weight presets at a locked 60fps; recommended holds the heaviest preset in the library at 60fps, every preset, no quality drop. Apple Silicon, macOS 15 or later."),
    h("div", { class: "hw-table" },
      h("table", {},
        h("thead", {},
          h("tr", {},
            h("th", { scope: "col" }, "Device"),
            h("th", { scope: "col" }, "Minimum"),
            h("th", { scope: "col" }, "Recommended"))),
        h("tbody", {},
          ...rows.map(([device, min, rec]) =>
            h("tr", {},
              h("th", { scope: "row" }, device),
              h("td", {}, check(min, "Minimum")),
              h("td", {}, check(rec, "Recommended"))))))),
  );
}

// A read-only checkbox cell: a filled box with a check when supported, an empty
// box otherwise.
function check(on: boolean, label: string): HTMLElement {
  return h("span",
    { class: "chk" + (on ? " chk--on" : ""), role: "img", "aria-label": `${label}: ${on ? "yes" : "no"}` },
    on && checkMark());
}
function checkMark(): SVGSVGElement {
  return svg(`<svg viewBox="0 0 24 24" width="14" height="14" fill="none" aria-hidden="true"><path d="M5 12.5 L10 17.5 L19 6.5" stroke="#08070d" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/></svg>`);
}

// ---- footer ----
function footer(): HTMLElement {
  return h("footer", { class: "wrap foot" },
    h("div", { class: "foot__brand" }, prismMark(), h("span", {}, "Spectra")),
    h("nav", { class: "foot__links", "aria-label": "Footer" },
      h("a", { href: "./eula.html" }, "License"),
      h("a", { href: "./privacy.html" }, "Privacy"),
      h("a", { href: "mailto:jacksoswag@proton.me" }, "Support")),
  );
}

// ---- helpers ----
function img(slug: string, kind: "before" | "after"): string {
  return `./looks/${slug}-${kind}.webp`;
}
function svg(markup: string): SVGSVGElement {
  const tpl = document.createElement("template");
  tpl.innerHTML = markup;
  return tpl.content.firstElementChild as SVGSVGElement;
}
export function prismMark(): SVGSVGElement {
  return svg(`<svg class="prism" viewBox="0 0 30 30" width="20" height="20" fill="none" aria-hidden="true"><defs><linearGradient id="pm" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff3df0"/><stop offset=".4" stop-color="#8b5cff"/><stop offset=".7" stop-color="#2fd9ff"/><stop offset="1" stop-color="#b6ff3d"/></linearGradient></defs><path d="M15 4 L26 23 L4 23 Z" stroke="url(#pm)" stroke-width="1.8" stroke-linejoin="round"/><path d="M0 14 L11 14" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/><path d="M19.5 14 L30 10.5" stroke="#ff3df0" stroke-width="1.4" stroke-linecap="round"/><path d="M20 16 L30 16" stroke="#8b5cff" stroke-width="1.4" stroke-linecap="round"/><path d="M19.5 18 L30 21.5" stroke="#2fd9ff" stroke-width="1.4" stroke-linecap="round"/></svg>`);
}
// Social links intentionally omitted until real account handles exist; re-add a
// SOCIAL array + icon helpers here and render them in footer() when ready.
