// Before/after drag-to-compare. Pure DOM: pointer drag plus a keyboard range
// input, driving one CSS custom property (--pct). Original on the left, graded on
// the right, so dragging left reveals the look. The drag is the whole interaction,
// so it stays live under prefers-reduced-motion.

import { h } from "./dom";

export interface CompareOpts {
  before: string;
  after: string;
  app: string;
  preset: string;
  start?: number; // initial divider %, default 50
  eager?: boolean; // load immediately (above the fold)
  fill?: boolean; // fill the parent instead of using an intrinsic aspect ratio
}

export function compare(o: CompareOpts): HTMLElement {
  const start = o.start ?? 50;
  const loading = o.eager ? "eager" : "lazy";
  const fetchpriority = o.eager ? "high" : "auto";

  const beforeImg = h("img", {
    class: "cmp__base", src: o.before, alt: `${o.app} without Spectra`,
    loading, fetchpriority, decoding: "async", draggable: false,
  });
  const afterImg = h("img", {
    class: "cmp__base", src: o.after, alt: `${o.app} graded with the ${o.preset} preset`,
    loading, fetchpriority, decoding: "async", draggable: false,
  });
  const afterWrap = h("div", { class: "cmp__after" }, afterImg);
  const handle = h("button", { class: "cmp__handle", type: "button", tabindex: "-1", "aria-hidden": "true" }, handleGlyph());
  const divider = h("div", { class: "cmp__divider" }, handle);

  const range = h("input", {
    class: "cmp__range", type: "range", min: "0", max: "100", value: String(start),
    "aria-label": `Reveal the ${o.preset} grade on ${o.app}`,
  }) as HTMLInputElement;

  const root = h("div", { class: "cmp" + (o.fill ? " cmp--fill" : "") },
    beforeImg, afterWrap, divider, range,
    h("span", { class: "cmp__tag cmp__tag--off" }, "before"),
    h("span", { class: "cmp__tag cmp__tag--on" }, "after"),
  );

  const set = (pct: number) => {
    const v = Math.max(0, Math.min(100, pct));
    root.style.setProperty("--pct", v + "%");
    range.value = String(Math.round(v));
  };
  set(start);

  range.addEventListener("input", () => set(Number(range.value)));

  let dragging = false;
  const fromX = (clientX: number) => {
    const r = root.getBoundingClientRect();
    set(((clientX - r.left) / r.width) * 100);
  };
  root.addEventListener("pointerdown", (e) => {
    if ((e.target as HTMLElement).closest(".cmp__range")) return;
    dragging = true;
    root.setPointerCapture(e.pointerId);
    root.classList.add("is-dragging");
    afterWrap.style.willChange = "clip-path";
    fromX(e.clientX);
  });
  root.addEventListener("pointermove", (e) => { if (dragging) fromX(e.clientX); });
  const end = (e: PointerEvent) => {
    if (!dragging) return;
    dragging = false;
    root.classList.remove("is-dragging");
    afterWrap.style.willChange = "auto";
    try { root.releasePointerCapture(e.pointerId); } catch { /* capture may be gone */ }
  };
  root.addEventListener("pointerup", end);
  root.addEventListener("pointercancel", end);

  return root;
}

function handleGlyph(): SVGSVGElement {
  const tpl = document.createElement("template");
  tpl.innerHTML =
    `<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6 4 12l5 6"/><path d="m15 6 5 6-5 6"/></svg>`;
  return tpl.content.firstElementChild as SVGSVGElement;
}
