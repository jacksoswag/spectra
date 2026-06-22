// Spectra cinematic — app-replica scenes.
// Each scene draws a full surface to a 2D context: draw(ctx, t, W, H). The director
// picks one per beat and the engine shades it through that beat's preset. SceneKit holds
// shared chrome so every replica is consistent. Exposes window.SCENES + window.SceneKit.

(() => {
  'use strict';

  const rr = (x, X, Y, W, H, r) => { x.beginPath(); x.moveTo(X + r, Y);
    x.arcTo(X + W, Y, X + W, Y + H, r); x.arcTo(X + W, Y + H, X, Y + H, r);
    x.arcTo(X, Y + H, X, Y, r); x.arcTo(X, Y, X + W, Y, r); x.closePath(); };

  const SceneKit = {
    rr,
    menuBar(x, W, apps, dark = true) {
      x.fillStyle = dark ? 'rgba(8,6,16,0.55)' : 'rgba(250,250,252,0.9)';
      x.fillRect(0, 0, W, 30);
      x.fillStyle = dark ? '#fff' : '#1a1a1a';
      x.font = '600 15px Inter, system-ui, sans-serif';
      x.fillText('', 16, 21);                                  // apple glyph fallback box is fine
      x.font = '500 14px Inter, system-ui, sans-serif';
      let px = 40; apps.forEach((a, i) => { x.font = i === 0 ? '700 14px Inter' : '500 14px Inter'; x.fillText(a, px, 21); px += x.measureText(a).width + 22; });
      x.textAlign = 'right'; x.font = '500 14px Inter'; x.fillText('100%   Sat 9:41', W - 16, 21); x.textAlign = 'left';
    },
    lights(x, X, Y) { ['#ff5f57', '#febc2e', '#28c840'].forEach((c, i) => { x.beginPath(); x.arc(X + i * 20, Y, 6.5, 0, 7); x.fillStyle = c; x.fill(); }); },
    window(x, X, Y, W, H, opts = {}) {
      rr(x, X, Y, W, H, opts.r || 14); x.fillStyle = opts.bg || 'rgba(20,16,34,0.92)'; x.fill();
      rr(x, X, Y, W, 40, opts.r || 14); x.fillStyle = opts.bar || 'rgba(36,28,60,0.96)'; x.fill();
      this.lights(x, X + 22, Y + 20);
      if (opts.title) { x.fillStyle = opts.titleColor || '#cfcae8'; x.font = '500 14px Inter'; x.textAlign = 'center'; x.fillText(opts.title, X + W / 2, Y + 25); x.textAlign = 'left'; }
    },
    dock(x, W, H, cols = ['#ff3df0', '#8b5cff', '#2fd9ff', '#b6ff3d', '#ffd23d', '#ff8a3d', '#3dffd2', '#ff5470']) {
      const dw = cols.length * 66 + 28, dx = (W - dw) / 2, dy = H - 84;
      rr(x, dx, dy, dw, 66, 20); x.fillStyle = 'rgba(245,244,255,0.15)'; x.fill();
      cols.forEach((c, i) => { rr(x, dx + 22 + i * 66, dy + 10, 46, 46, 12); x.fillStyle = c; x.fill(); });
    },
    cursor(x, X, Y) { x.save(); x.translate(X, Y); x.fillStyle = '#fff'; x.strokeStyle = '#000'; x.lineWidth = 1.5;
      x.beginPath(); x.moveTo(0, 0); x.lineTo(0, 18); x.lineTo(5, 13); x.lineTo(9, 21); x.lineTo(12, 19); x.lineTo(8, 11); x.lineTo(15, 11); x.closePath(); x.fill(); x.stroke(); x.restore(); },
  };

  const SCENES = {
    // The Spectra homepage — the calm "normal" surface the loop starts and ends on.
    spectra(x, t, W, H) {
      const g = x.createLinearGradient(0, 0, W, H);
      g.addColorStop(0, '#0c0a18'); g.addColorStop(1, '#120a22'); x.fillStyle = g; x.fillRect(0, 0, W, H);
      for (let i = 0; i < 4; i++) { const bx = W * (0.2 + 0.2 * i), by = H * (0.3 + 0.1 * (i % 2));
        const rg = x.createRadialGradient(bx, by, 0, bx, by, 360); rg.addColorStop(0, ['#ff3df0', '#8b5cff', '#2fd9ff', '#b6ff3d'][i] + '33'); rg.addColorStop(1, '#0000'); x.fillStyle = rg; x.fillRect(0, 0, W, H); }
      SceneKit.menuBar(x, W, ['Spectra', 'File', 'Edit', 'Effects', 'Window']);
      x.fillStyle = '#f4f2ff'; x.font = '700 72px "Space Grotesk", Inter, sans-serif';
      x.fillText('Your whole desktop,', W * 0.12, H * 0.42);
      x.fillStyle = '#9b7bff'; x.fillText('shaded in real time.', W * 0.12, H * 0.42 + 84);
      x.fillStyle = '#a9a3cc'; x.font = '400 26px Inter, sans-serif';
      x.fillText('16 worlds · 169 effects · one click-through overlay.', W * 0.12, H * 0.42 + 140);
      rr(x, W * 0.12, H * 0.42 + 180, 250, 64, 32); x.fillStyle = '#ff3df0'; x.fill();
      x.fillStyle = '#2a0726'; x.font = '600 24px Inter'; x.fillText('Get Spectra — $9.99', W * 0.12 + 34, H * 0.42 + 220);
      SceneKit.dock(x, W, H);
    },

    // macOS desktop — the base surface for Painting / Night Light flips.
    desktop(x, t, W, H) {
      const g = x.createLinearGradient(0, 0, 0, H);
      g.addColorStop(0, '#3a2d6b'); g.addColorStop(0.5, '#5b3f8c'); g.addColorStop(1, '#b06a8f'); x.fillStyle = g; x.fillRect(0, 0, W, H);
      const sun = x.createRadialGradient(W * 0.72, H * 0.3, 0, W * 0.72, H * 0.3, 420);
      sun.addColorStop(0, '#ffd9a855'); sun.addColorStop(1, '#0000'); x.fillStyle = sun; x.fillRect(0, 0, W, H);
      x.fillStyle = '#241b3e'; x.beginPath(); x.moveTo(0, H * 0.72); for (let i = 0; i <= W; i += 40) x.lineTo(i, H * 0.72 + Math.sin(i * 0.01) * 26); x.lineTo(W, H); x.lineTo(0, H); x.closePath(); x.fill();
      SceneKit.menuBar(x, W, ['Finder', 'File', 'Edit', 'View', 'Go']);
      // desktop icons top-right
      ['Spectra', 'Notes', 'Shots'].forEach((n, i) => { rr(x, W - 96, 56 + i * 96, 56, 56, 12); x.fillStyle = ['#8b5cff', '#ffd23d', '#2fd9ff'][i]; x.fill();
        x.fillStyle = '#fff'; x.font = '500 13px Inter'; x.textAlign = 'center'; x.fillText(n, W - 68, 130 + i * 96); x.textAlign = 'left'; });
      SceneKit.dock(x, W, H);
    },

    // Google Docs — warm document surface, the canonical Fuji-Film match.
    docs(x, t, W, H) {
      x.fillStyle = '#f1f3f4'; x.fillRect(0, 0, W, H);
      x.fillStyle = '#fff'; x.fillRect(0, 0, W, 96);                 // app header
      x.fillStyle = '#1a73e8'; rr(x, 22, 20, 36, 36, 8); x.fill();
      x.fillStyle = '#202124'; x.font = '500 20px Inter'; x.fillText('Spectra — launch notes', 72, 38);
      x.fillStyle = '#5f6368'; x.font = '400 14px Inter'; ['File', 'Edit', 'View', 'Insert', 'Format', 'Tools'].forEach((m, i) => x.fillText(m, 72 + i * 70, 64));
      x.fillStyle = '#edf2fa'; x.fillRect(0, 96, W, 48);             // toolbar
      for (let i = 0; i < 10; i++) { x.fillStyle = '#5f6368'; x.beginPath(); x.arc(60 + i * 44, 120, 8, 0, 7); x.fill(); }
      const pw = W * 0.62, pxg = (W - pw) / 2;                       // the page
      x.fillStyle = '#fff'; x.shadowColor = 'rgba(0,0,0,0.18)'; x.shadowBlur = 24; x.fillRect(pxg, 168, pw, H); x.shadowBlur = 0;
      x.fillStyle = '#202124'; x.font = '600 34px Georgia, serif'; x.fillText('Spectra 1.0 — what ships', pxg + 60, 250);
      x.fillStyle = '#3c4043'; x.font = '400 18px Georgia, serif';
      const lines = ['16 preset worlds, from cinematic to painterly.', '169 real-time GPU effects across 14 categories.', 'A click-through overlay over your whole desktop.', 'One-time $9.99 — four cinematic worlds free.', '', 'So real it can’t be screen-captured.'];
      lines.forEach((l, i) => { if (l) x.fillText(l, pxg + 60, 300 + i * 36); });
      for (let i = 0; i < 6; i++) { x.fillStyle = '#e8eaed'; x.fillRect(pxg + 60, 520 + i * 30, pw - 120 - (i % 3) * 80, 12); }
    },

    // YouTube — a colourful video so CRT scanlines + VHS chroma-bleed have material.
    youtube(x, t, W, H) {
      x.fillStyle = '#f9f9f9'; x.fillRect(0, 0, W, H);
      x.fillStyle = '#fff'; x.fillRect(0, 0, W, 72);
      x.fillStyle = '#ff0000'; rr(x, 40, 22, 36, 26, 6); x.fill();
      x.fillStyle = '#fff'; x.beginPath(); x.moveTo(52, 30); x.lineTo(52, 42); x.lineTo(66, 36); x.closePath(); x.fill();
      x.fillStyle = '#0f0f0f'; x.font = '700 24px Inter'; x.fillText('YouTube', 86, 46);
      x.strokeStyle = '#ccc'; x.lineWidth = 1; rr(x, 560, 20, 540, 36, 18); x.fillStyle = '#fff'; x.fill(); x.stroke();
      x.fillStyle = '#909090'; x.font = '400 16px Inter'; x.fillText('Search', 582, 43);
      x.fillStyle = '#ff3df0'; x.beginPath(); x.arc(W - 60, 40, 18, 0, 7); x.fill();
      const px = 40, py = 96, pw = 1040, ph = 586;
      const sky = x.createLinearGradient(px, py, px, py + ph);
      sky.addColorStop(0, '#3aa0ff'); sky.addColorStop(0.55, '#ffd36b'); sky.addColorStop(1, '#ff7e5f');
      x.fillStyle = sky; x.fillRect(px, py, pw, ph);
      x.fillStyle = 'rgba(255,255,255,0.85)'; x.beginPath(); x.arc(px + pw * 0.7, py + ph * 0.32, 64, 0, 7); x.fill();
      x.fillStyle = '#2e7d32'; x.beginPath(); x.moveTo(px, py + ph * 0.72); for (let i = 0; i <= pw; i += 40) x.lineTo(px + i, py + ph * 0.72 + Math.sin(i * 0.008 + 1) * 26); x.lineTo(px + pw, py + ph); x.lineTo(px, py + ph); x.closePath(); x.fill();
      x.fillStyle = 'rgba(0,0,0,0.32)'; x.fillRect(px, py + ph - 32, pw, 32);
      const prog = (t * 0.05) % 1; x.fillStyle = '#ff0000'; x.fillRect(px, py + ph - 6, pw * prog, 6);
      x.beginPath(); x.arc(px + pw * prog, py + ph - 3, 8, 0, 7); x.fill();
      x.fillStyle = '#0f0f0f'; x.font = '600 26px Inter'; x.fillText('Shading my entire Mac in real time — Spectra', px, py + ph + 48);
      x.fillStyle = '#2fd9ff'; x.beginPath(); x.arc(px + 22, py + ph + 84, 20, 0, 7); x.fill();
      x.fillStyle = '#606060'; x.font = '400 15px Inter'; x.fillText('Spectra  ·  168K views  ·  16 worlds', px + 56, py + ph + 88);
      const cols = ['#ff6b9d', '#ffd23d', '#3dd6ff', '#b6ff3d', '#c77dff'];
      for (let i = 0; i < 5; i++) { const sy = 96 + i * 134; rr(x, 1110, sy, 168, 94, 8); x.fillStyle = cols[i]; x.fill();
        x.fillStyle = '#0f0f0f'; x.fillRect(1290, sy + 8, 250, 13); x.fillStyle = '#aaa'; x.fillRect(1290, sy + 32, 180, 10); x.fillRect(1290, sy + 50, 140, 10); }
    },

    // Spotify — vivid album art gives Cyberpunk bright dual-tone sources.
    spotify(x, t, W, H) {
      x.fillStyle = '#121212'; x.fillRect(0, 0, W, H);
      x.fillStyle = '#000'; x.fillRect(0, 0, 300, H);
      x.fillStyle = '#1db954'; x.beginPath(); x.arc(40, 46, 18, 0, 7); x.fill();
      x.fillStyle = '#fff'; x.font = '700 22px Inter'; x.fillText('Spotify', 70, 54);
      x.fillStyle = '#b3b3b3'; x.font = '500 16px Inter';
      ['Home', 'Search', 'Your Library', '', 'Liquid Glass', 'Synthwave Nights', 'Focus Flow', 'Coding 2026'].forEach((s, i) => { if (s) x.fillText(s, 28, 116 + i * 40); });
      const hg = x.createLinearGradient(300, 0, 300, 420); hg.addColorStop(0, '#5b2a86'); hg.addColorStop(1, '#121212'); x.fillStyle = hg; x.fillRect(300, 0, W - 300, 420);
      const ag = x.createLinearGradient(340, 60, 640, 360); ag.addColorStop(0, '#ff3df0'); ag.addColorStop(0.5, '#8b5cff'); ag.addColorStop(1, '#2fd9ff');
      x.fillStyle = ag; rr(x, 340, 60, 300, 300, 6); x.fill();
      x.fillStyle = '#fff'; x.font = '800 60px "Space Grotesk", Inter'; x.fillText('Neon City', 680, 210);
      x.fillStyle = '#b3b3b3'; x.font = '500 18px Inter'; x.fillText('Spectra  ·  Cyberpunk  ·  2026', 680, 246);
      x.fillStyle = '#1db954'; x.beginPath(); x.arc(704, 320, 30, 0, 7); x.fill();
      x.fillStyle = '#000'; x.beginPath(); x.moveTo(697, 306); x.lineTo(697, 334); x.lineTo(719, 320); x.closePath(); x.fill();
      const titles = ['Midnight Drive', 'Neon City', 'Magenta Rain', 'Crushed Blacks', 'Bloom', 'Afterglow', 'Reset'];
      const times = ['3:21', '2:58', '4:04', '3:33', '2:47', '3:12', '1:09'];
      x.font = '500 16px Inter';
      for (let i = 0; i < 7; i++) { const ty = 474 + i * 46; const on = i === 1;
        x.fillStyle = on ? '#1db954' : '#b3b3b3'; x.fillText(String(i + 1), 332, ty);
        x.fillStyle = on ? '#1db954' : '#fff'; x.fillText(titles[i], 384, ty);
        x.fillStyle = '#6a6a6a'; x.fillText(times[i], W - 130, ty); }
      x.fillStyle = '#181818'; x.fillRect(0, H - 90, W, 90);
      const mb = x.createLinearGradient(20, H - 78, 76, H - 22); mb.addColorStop(0, '#ff3df0'); mb.addColorStop(1, '#2fd9ff'); x.fillStyle = mb; rr(x, 20, H - 78, 56, 56, 6); x.fill();
      x.fillStyle = '#fff'; x.font = '500 14px Inter'; x.fillText('Neon City', 90, H - 50); x.fillStyle = '#b3b3b3'; x.fillText('Spectra', 90, H - 30);
      x.fillStyle = '#404040'; x.fillRect(W / 2 - 200, H - 46, 400, 4); x.fillStyle = '#1db954'; x.fillRect(W / 2 - 200, H - 46, 400 * ((t * 0.06) % 1), 4);
    },

    // Terminal — Matrix is procedural, so this one stays dark/green and just sells "a real shell".
    terminal(x, t, W, H) {
      const g = x.createLinearGradient(0, 0, W, H); g.addColorStop(0, '#1a1430'); g.addColorStop(1, '#0a0a14'); x.fillStyle = g; x.fillRect(0, 0, W, H);
      SceneKit.menuBar(x, W, ['Terminal', 'Shell', 'Edit', 'View']);
      SceneKit.window(x, 300, 150, 1000, 680, { bg: '#0c0c14', bar: '#23232e', title: 'jackson — -zsh — 100×34', r: 12 });
      x.font = '15px ui-monospace, Menlo, monospace';
      const rows = [
        [['#7ee787', 'jackson@spectra'], ['#c9d1d9', ' ~/Code/spectra % '], ['#ffffff', 'swift build']],
        [['#8b949e', 'Compiling Spectra (169 effects across 14 categories)…']],
        [['#7ee787', 'Build complete!'], ['#8b949e', '   (2.1s)']], [],
        [['#79c0ff', 'jackson@spectra'], ['#c9d1d9', ' ~ % '], ['#ffffff', 'git status']],
        [['#8b949e', 'On branch '], ['#d2a8ff', 'ship/phase-1']],
        [['#7ee787', 'nothing to commit, working tree clean']], [],
        [['#79c0ff', 'jackson@spectra'], ['#c9d1d9', ' ~ % '], ['#ffffff', 'spectra --shade all']],
        [['#b6ff3d', '▸ overlay live · 60 fps · 16 worlds ready']], [],
      ];
      let y = 226;
      rows.forEach(row => { let cx = 330; row.forEach(([c, txt]) => { x.fillStyle = c; x.fillText(txt, cx, y); cx += x.measureText(txt).width; }); y += 30; });
      x.fillStyle = '#79c0ff'; x.fillText('jackson@spectra', 330, y); let pw2 = x.measureText('jackson@spectra').width;
      x.fillStyle = '#c9d1d9'; x.fillText(' ~ % ', 330 + pw2, y); pw2 += x.measureText(' ~ % ').width;
      if (Math.floor(t * 1.6) % 2 === 0) { x.fillStyle = '#b6ff3d'; x.fillRect(334 + pw2, y - 14, 9, 18); }
    },

    // Photos — a warm sunset hero (Golden Hour glows) + a colourful grid (Comic posterises).
    photos(x, t, W, H) {
      x.fillStyle = '#f5f5f7'; x.fillRect(0, 0, W, H);
      x.fillStyle = '#ececef'; x.fillRect(0, 0, 240, H);
      x.fillStyle = '#1d1d1f'; x.font = '600 15px Inter';
      ['Library', 'Memories', 'People', 'Places', 'Albums'].forEach((s, i) => x.fillText(s, 24, 66 + i * 40));
      x.fillStyle = '#fff'; x.fillRect(240, 0, W - 240, 56);
      x.fillStyle = '#1d1d1f'; x.font = '600 18px Inter'; x.fillText('Photos', 268, 36);
      const hx = 270, hy = 80, hw = 800, hh = 520;
      rr(x, hx, hy, hw, hh, 12); x.save(); x.clip();
      const sky = x.createLinearGradient(hx, hy, hx, hy + hh);
      sky.addColorStop(0, '#2a3a8c'); sky.addColorStop(0.45, '#ff8a4c'); sky.addColorStop(0.72, '#ffd36b'); sky.addColorStop(1, '#7a3b6e');
      x.fillStyle = sky; x.fillRect(hx, hy, hw, hh);
      x.fillStyle = '#fff6d8'; x.beginPath(); x.arc(hx + hw * 0.5, hy + hh * 0.5, 72, 0, 7); x.fill();
      x.fillStyle = '#3a2b5c'; x.beginPath(); x.moveTo(hx, hy + hh * 0.62); for (let i = 0; i <= hw; i += 30) x.lineTo(hx + i, hy + hh * 0.62 + Math.sin(i * 0.01) * 30); x.lineTo(hx + hw, hy + hh); x.lineTo(hx, hy + hh); x.closePath(); x.fill();
      x.fillStyle = 'rgba(255,170,90,0.35)'; x.fillRect(hx, hy + hh * 0.72, hw, hh * 0.28);
      x.restore();
      const cols = ['#ff6b9d', '#ffd23d', '#3dd6ff', '#b6ff3d', '#c77dff', '#ff8a3d', '#36e0a8', '#7d8cff', '#ff5470', '#5fe0c0'];
      for (let i = 0; i < 10; i++) { const gx = 1100 + (i % 2) * 222, gy = 80 + Math.floor(i / 2) * 178;
        const gg = x.createLinearGradient(gx, gy, gx + 200, gy + 158); gg.addColorStop(0, cols[i]); gg.addColorStop(1, cols[(i + 4) % 10]);
        rr(x, gx, gy, 200, 158, 8); x.fillStyle = gg; x.fill(); }
    },

    // Figma — many distinct colour regions for the Kuwahara oil-cell Painting shader.
    figma(x, t, W, H) {
      x.fillStyle = '#2c2c2c'; x.fillRect(0, 0, W, H);
      x.fillStyle = '#1e1e1e'; x.fillRect(0, 0, W, 48);
      ['#ff5470', '#ffd23d', '#3dd6ff', '#b6ff3d'].forEach((c, i) => { x.fillStyle = c; x.beginPath(); x.arc(42 + i * 36, 24, 9, 0, 7); x.fill(); });
      x.fillStyle = '#bdbdbd'; x.font = '500 14px Inter'; x.fillText('Spectra UI — Draft', W / 2 - 70, 29);
      x.fillStyle = '#1e1e1e'; x.fillRect(0, 48, 260, H);
      x.fillStyle = '#e0e0e0'; x.font = '500 13px Inter';
      ['Frame / Hero', '  Background', '  Headline', '  CTA button', '  Prism', 'Frame / Pricing', '  Card · Free', '  Card · $9.99'].forEach((s, i) => x.fillText(s, 16, 92 + i * 30));
      x.fillStyle = '#1e1e1e'; x.fillRect(W - 260, 48, 260, H);
      x.fillStyle = '#9a9a9a'; x.font = '500 13px Inter'; x.fillText('Fill', W - 244, 92);
      ['#ff3df0', '#8b5cff', '#2fd9ff', '#b6ff3d'].forEach((c, i) => { x.fillStyle = c; rr(x, W - 244 + i * 42, 104, 32, 32, 6); x.fill(); });
      const ax = 320, ay = 96, aw = W - 640, ah = H - 200;
      x.fillStyle = '#fff'; rr(x, ax, ay, aw, ah, 8); x.fill();
      const hgr = x.createLinearGradient(ax, ay, ax + aw, ay); hgr.addColorStop(0, '#ff3df0'); hgr.addColorStop(1, '#8b5cff');
      x.fillStyle = hgr; x.fillRect(ax + 40, ay + 40, aw - 80, 120);
      x.fillStyle = '#fff'; x.font = '700 30px "Space Grotesk", Inter'; x.fillText('Your desktop, shaded', ax + 70, ay + 112);
      const cw = (aw - 120) / 3;
      ['#2fd9ff', '#b6ff3d', '#ffd23d'].forEach((c, i) => { const cxx = ax + 40 + i * (cw + 20);
        x.fillStyle = '#f2f2f4'; rr(x, cxx, ay + 190, cw, 200, 10); x.fill();
        x.fillStyle = c; rr(x, cxx + 16, ay + 206, cw - 32, 72, 8); x.fill();
        x.fillStyle = '#888'; x.fillRect(cxx + 16, ay + 292, cw - 60, 12); x.fillRect(cxx + 16, ay + 314, cw - 100, 12); });
      const bx = ax + 40, by = ay + 430;
      ['#ff3df0', '#8b5cff', '#2fd9ff', '#b6ff3d', '#ffd23d'].forEach((c, i) => { const bh = 50 + (i * 27 % 96); x.fillStyle = c; x.fillRect(bx + i * 56, by + 120 - bh, 40, bh); });
      x.strokeStyle = '#2fd9ff'; x.lineWidth = 2; x.strokeRect(ax + 40, ay + 40, aw - 80, 120);
      [[ax + 40, ay + 40], [ax + aw - 40, ay + 40], [ax + 40, ay + 160], [ax + aw - 40, ay + 160]].forEach(([hx, hy]) => { x.fillStyle = '#fff'; rr(x, hx - 5, hy - 5, 10, 10, 2); x.fill(); x.stroke(); });
    },
  };

  window.SceneKit = SceneKit;
  window.SCENES = SCENES;
})();
