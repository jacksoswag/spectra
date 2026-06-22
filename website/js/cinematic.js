// Spectra cinematic — the director.
// Runs the global clock (play/pause, 2x, loop), draws the current scene to an offscreen
// 2D canvas, shades it through the engine, then paints characters + orb + props + UI on
// top. Wires the bottom controls. Vanilla, no deps.

(() => {
  'use strict';
  const { SHOTS, VW, VH, G } = window.STORY;
  const S = window.SPECTRA_SHADERS;

  // ---- compile shots once: build rig characters + cumulative start times -------------
  let total = 0;
  const shots = SHOTS.map(sh => {
    const c = { ...sh, startT: total, cyanC: Rig.character(sh.cyan), magentaC: Rig.character(sh.magenta) };
    total += sh.dur; return c;
  });
  const LOOP = total;

  const handPos = (s) => [s.world.x + s.world.flip * s.pose.hR[0] * s.world.s, s.world.y + s.pose.hR[1] * s.world.s];

  function sampleOrb(keys, lt, cy, mg) {
    let a = keys[0]; for (let i = 0; i < keys.length - 1; i++) if (keys[i + 1].t <= lt) a = keys[i + 1];
    let b = a; for (let i = 0; i < keys.length; i++) if (keys[i].t > lt) { b = keys[i]; break; }
    const held = a.held;
    if (held === 'cyan') return handPos(cy);
    if (held === 'magenta') return handPos(mg);
    const span = Math.max(1e-4, b.t - a.t), e = Math.min(1, Math.max(0, (lt - a.t) / span));
    return [a.x + (b.x - a.x) * e, a.y + (b.y - a.y) * e];
  }

  const css = (c, a = 1) => `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${a})`;

  // ---- props ------------------------------------------------------------------
  function drawWall(ctx, [t0, t1, xV], lt) {
    const p = Math.min(1, Math.max(0, (lt - t0) / (t1 - t0)));
    if (p <= 0) return;
    const h = p * 360, top = G - h, palette = ['#c2613f', '#7a9e6b', '#3f6ea8', '#caa24a', '#9d5ba0'];
    for (let y = G; y > top; y -= 26) for (let bx = -1; bx <= 1; bx++) {
      ctx.fillStyle = palette[(Math.abs(Math.round(y)) + bx + 5) % palette.length];
      ctx.globalAlpha = 0.92; ctx.fillRect(xV - 36 + bx * 24, y - 24, 22, 22);
    }
    ctx.globalAlpha = 1;
  }
  function drawPow(ctx, vx, vy) {
    ctx.save(); ctx.translate(vx, vy);
    ctx.fillStyle = '#ffd23d'; ctx.strokeStyle = '#1a1206'; ctx.lineWidth = 4; ctx.beginPath();
    for (let i = 0; i < 24; i++) { const a = i / 24 * Math.PI * 2, r = i % 2 ? 28 : 56; ctx[i ? 'lineTo' : 'moveTo'](Math.cos(a) * r, Math.sin(a) * r); }
    ctx.closePath(); ctx.fill(); ctx.stroke();
    ctx.fillStyle = '#ff5470'; ctx.font = '900 34px "Space Grotesk", sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText('POW', 0, 2); ctx.textAlign = 'left'; ctx.textBaseline = 'alphabetic'; ctx.restore();
  }
  function drawBlinds(ctx) {
    ctx.save(); ctx.globalCompositeOperation = 'overlay';
    for (let i = -2; i < 14; i++) { ctx.fillStyle = 'rgba(255,255,255,0.10)'; ctx.beginPath();
      ctx.moveTo(i * 130, 0); ctx.lineTo(i * 130 + 60, 0); ctx.lineTo(i * 130 + 60 + 300, VH); ctx.lineTo(i * 130 + 300, VH); ctx.closePath(); ctx.fill(); }
    ctx.restore();
  }
  function drawMagnifier(ctx, cy) {
    const [hx, hy] = handPos(cy);
    ctx.save(); ctx.strokeStyle = '#d8dae0'; ctx.lineWidth = 5;
    ctx.beginPath(); ctx.arc(hx + 10, hy + 8, 18, 0, 7); ctx.stroke();
    ctx.strokeStyle = 'rgba(216,218,224,0.25)'; ctx.lineWidth = 1; ctx.beginPath(); ctx.arc(hx + 10, hy + 8, 16, 0, 7); ctx.stroke();
    ctx.restore();
  }

  function drawOrb(ctx, vx, vy, spin, flash, fcol) {
    ctx.save(); ctx.translate(vx, vy);
    if (flash > 0) { ctx.globalAlpha = flash; ctx.fillStyle = css(fcol, 0.5); ctx.beginPath(); ctx.arc(0, 0, 30 + (1 - flash) * 220, 0, 7); ctx.fill(); ctx.globalAlpha = 1; }
    ctx.fillStyle = 'rgba(160,130,255,0.35)'; ctx.beginPath(); ctx.arc(0, 0, 30, 0, 7); ctx.fill();
    ctx.rotate(spin); const r = 16;
    ctx.beginPath(); ctx.moveTo(0, -r); ctx.lineTo(r * 0.82, 0); ctx.lineTo(0, r); ctx.lineTo(-r * 0.82, 0); ctx.closePath();
    ctx.fillStyle = '#fff'; ctx.fill();
    const cols = ['#ff3df0', '#2fd9ff', '#b6ff3d', '#8b5cff'], pts = [[0, -r], [r * 0.82, 0], [0, r], [-r * 0.82, 0]];
    ctx.lineWidth = 2.5; for (let i = 0; i < 4; i++) { ctx.strokeStyle = cols[i]; ctx.beginPath(); ctx.moveTo(pts[i][0], pts[i][1]); ctx.lineTo(pts[(i + 1) % 4][0], pts[(i + 1) % 4][1]); ctx.stroke(); }
    ctx.restore();
  }

  // ---- boot -------------------------------------------------------------------
  const stage = document.getElementById('stage');
  const actors = document.getElementById('actors');
  if (!stage || !actors) return;
  if (!Engine.init(stage)) { document.body.classList.add('no-gl'); return; }
  Characters.init(document.getElementById('fighters'));   // upgrades to the Rive rig if assets/fighters.riv loads
  const actx = actors.getContext('2d');
  const scene = document.createElement('canvas'); scene.width = 1600; scene.height = 1000;
  const sctx = scene.getContext('2d');

  let playing = true, speed = 1, clock = 0, lastReal = performance.now(), curIdx = -1;
  const sub = document.getElementById('subtitle');
  const factEl = document.getElementById('fact');
  const ppBtn = document.getElementById('playPause');
  const spBtn = document.getElementById('speed');
  const scrub = document.getElementById('scrub');

  shots.forEach((sh, i) => { const p = document.createElement('button'); p.className = 'pip'; p.type = 'button';
    p.title = sh.name; p.innerHTML = '<span></span>'; p.addEventListener('click', () => { clock = sh.startT + 0.001; }); scrub.appendChild(p); });
  const pips = [...scrub.children];

  ppBtn.addEventListener('click', () => { playing = !playing; ppBtn.textContent = playing ? '⏸' : '▶'; ppBtn.setAttribute('aria-label', playing ? 'Pause' : 'Play'); });
  spBtn.addEventListener('click', () => { speed = speed === 1 ? 2 : 1; spBtn.textContent = speed + '×'; });

  function resize() { const dpr = Math.min(devicePixelRatio || 1, 1.4); actors.width = innerWidth * dpr; actors.height = innerHeight * dpr; }
  addEventListener('resize', resize); resize();

  function frame(real) {
    const dt = Math.min(0.05, (real - lastReal) / 1000) * speed; lastReal = real;
    if (playing) clock = (clock + dt) % LOOP;

    let idx = 0; for (let i = 0; i < shots.length; i++) if (clock >= shots[i].startT) idx = i;
    const sh = shots[idx], lt = Math.min(1, (clock - sh.startT) / sh.dur);
    const cy = sh.cyanC.sample(lt), mg = sh.magentaC.sample(lt);
    const [ovx, ovy] = sampleOrb(sh.orb, lt, cy, mg);

    if (idx !== curIdx) {
      curIdx = idx;
      const sx = ovx / VW, sy = ovy / VH;
      Engine.setPreset(sh.preset, [sx, sy], false);
      if (sub) sub.textContent = sh.sub || '';
      if (factEl && sh.fact) factEl.textContent = sh.fact;
      pips.forEach((p, i) => p.classList.toggle('on', i === idx));
    }
    pips[idx].firstChild.style.transform = `scaleX(${lt})`;

    // 1. draw the surface, shade it
    const draw = (window.SCENES[sh.scene] || window.SCENES.desktop);
    draw(sctx, clock, scene.width, scene.height);
    Engine.render(scene, clock);

    // 2. actors layer in virtual space
    const w = actors.width, h = actors.height, sc = Math.max(w / VW, h / VH);
    const ox = (w - VW * sc) / 2, oy = (h - VH * sc) / 2;
    actx.setTransform(1, 0, 0, 1, 0, 0); actx.clearRect(0, 0, w, h);
    actx.setTransform(sc, 0, 0, sc, ox, oy);

    // Rive rig (own layer, CSS-px space) when available; else the director draws the canvas rig.
    const csc = Math.max(innerWidth / VW, innerHeight / VH);
    const cssView = { sc: csc, ox: (innerWidth - VW * csc) / 2, oy: (innerHeight - VH * csc) / 2 };
    Characters.apply('magenta', mg, cssView); Characters.apply('cyan', cy, cssView);

    if (sh.props?.blinds) drawBlinds(actx);
    if (sh.props?.wall) drawWall(actx, sh.props.wall, lt);

    if (Characters.mode !== 'rive') {
      Rig.drawFigure(actx, mg.world, mg.pose, '#ff3df0', { glow: true });
      Rig.drawFigure(actx, cy.world, cy.pose, '#2fd9ff', { glow: true });
    }

    const flash = Engine.busy() ? Math.max(0, 1 - (clock - sh.startT) / 0.55) : 0;
    drawOrb(actx, ovx, ovy, clock * 2.2, flash, S.SIGNATURE[sh.preset] || [1, 1, 1]);

    if (sh.props?.pow && lt >= sh.props.pow[0] && lt <= sh.props.pow[1]) drawPow(actx, ovx, ovy - 70);
    if (sh.props?.magnifier === 'cyan') drawMagnifier(actx, cy);

    // 3. screen-space overlays
    actx.setTransform(1, 0, 0, 1, 0, 0);
    if (sh.props?.paused && lt >= sh.props.paused[0]) {
      actx.fillStyle = 'rgba(0,0,0,0.35)'; actx.fillRect(0, 0, w, 40 * sc / 1);
      actx.fillStyle = '#fff'; actx.font = `700 ${22}px "Space Grotesk", monospace`;
      actx.fillText('❚❚  PAUSED   ' + (clock).toFixed(2).replace('.', ':'), 20, 30);
    }
    let veil = 0;
    if (sh.name === 'discover') veil = 1 - Math.min(1, lt / 0.14);
    if (sh.props?.fade) veil = Math.max(0, (lt - 0.55) / 0.45);
    if (veil > 0) { actx.fillStyle = `rgba(4,3,9,${veil})`; actx.fillRect(0, 0, w, h); }

    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
})();
