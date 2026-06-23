// Tiny element builder — keeps the page modules declarative without a framework.
type Attrs = Record<string, string | number | boolean | ((e: Event) => void)>;
type Child = Node | string | null | undefined | false;

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Attrs = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const k in attrs) {
    const v = attrs[k];
    if (k === "class") el.className = String(v);
    else if (k === "html") el.innerHTML = String(v);
    else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v as EventListener);
    else if (typeof v === "boolean") { if (v) el.setAttribute(k, ""); }
    else el.setAttribute(k, String(v));
  }
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

export function frag(...children: Child[]): DocumentFragment {
  const f = document.createDocumentFragment();
  for (const c of children) if (c) f.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return f;
}
