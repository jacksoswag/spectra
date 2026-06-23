import "./styles.css";
import { buildPage } from "./ui/page";

// Mark JS as live so the reveal animations engage. Without JS the page renders
// fully visible (progressive enhancement).
document.documentElement.classList.add("js");

document.getElementById("app")!.append(buildPage());

// Reveal each block as it enters view, staging the page top-down. CSS drops this
// instantly under prefers-reduced-motion.
const io = new IntersectionObserver((entries) => {
  for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
}, { threshold: 0.12, rootMargin: "0px 0px -8% 0px" });
for (const el of document.querySelectorAll(".look, .engine, .catalog, .close")) io.observe(el);
