// Spectra cinematic — character backend.
// Prefers a real Rive rig (assets/fighters.riv) and drives its state machine from the
// choreography; if the .riv or the Rive runtime is absent, falls back to the canvas
// stick rig (the director draws those itself). Keeps the page working until the rig
// drops in. See RIVE_SPEC.md for the exact artboard / state-machine contract.

(() => {
  'use strict';

  // pose name (from js/rig.js POSES) -> the Rive "action" Number input value.
  const ACTION = {
    idle: 0, walkA: 1, walkB: 1, runA: 2, runB: 2, reach: 3, grab: 4, present: 12,
    punch: 5, recoil: 6, jump: 7, crouch: 8, paint: 9, dodge: 10, amazed: 11,
    detective: 13, frozen: 14, down: 15,
  };

  const SRC = 'assets/fighters.riv', SM = 'Loco';
  const CW = 240, CH = 320, CHAR_H = 280;   // canvas box (CSS px) + standing-character height inside it

  let mode = 'canvas';
  const chars = {};

  function makeCanvas(layer) {
    const c = document.createElement('canvas');
    const dpr = Math.min(devicePixelRatio || 1, 2);
    c.width = CW * dpr; c.height = CH * dpr;
    c.style.cssText = `position:absolute;width:${CW}px;height:${CH}px;left:0;top:0;transform-origin:50% 100%;will-change:transform,left,top;`;
    layer.appendChild(c); return c;
  }

  function load(canvas, artboard) {
    return new Promise((res, rej) => {
      if (!window.rive) { rej('no-runtime'); return; }
      let done = false;
      const r = new rive.Rive({
        src: SRC, canvas, artboard, stateMachines: SM, autoplay: true,
        layout: new rive.Layout({ fit: rive.Fit.contain, alignment: rive.Alignment.bottomCenter }),
        onLoad: () => {
          done = true;
          const inputs = r.stateMachineInputs(SM) || [];
          res({ r, action: inputs.find(i => i.name === 'action'), flip: inputs.find(i => i.name === 'flip') });
        },
        onLoadError: () => { if (!done) rej('load-error'); },
      });
      setTimeout(() => { if (!done) rej('timeout'); }, 4000);
    });
  }

  const Characters = {
    get mode() { return mode; },

    async init(layer) {
      if (!layer || !window.rive) { mode = 'canvas'; return; }
      try {
        const cyC = makeCanvas(layer), mgC = makeCanvas(layer);
        const [cy, mg] = await Promise.all([load(cyC, 'Cyan'), load(mgC, 'Magenta')]);
        chars.cyan = { canvas: cyC, ...cy }; chars.magenta = { canvas: mgC, ...mg };
        mode = 'rive';
      } catch (e) { mode = 'canvas'; layer.innerHTML = ''; }
    },

    // s = a rig sample { world, action }; view = CSS-px virtual->screen transform { sc, ox, oy }.
    apply(who, s, view) {
      if (mode !== 'rive') return;
      const c = chars[who]; if (!c) return;
      const feetX = view.ox + s.world.x * view.sc;
      const feetY = view.oy + (s.world.y + 30 * s.world.s) * view.sc;
      const scale = (76 * s.world.s * view.sc) / CHAR_H;
      const faceLeft = s.world.flip < 0;
      c.canvas.style.left = (feetX - CW / 2) + 'px';
      c.canvas.style.top = (feetY - CH) + 'px';
      c.canvas.style.transform = `scale(${scale.toFixed(3)})${faceLeft ? ' scaleX(-1)' : ''}`;
      if (c.action) c.action.value = ACTION[s.action] != null ? ACTION[s.action] : 0;
      if (c.flip) c.flip.value = faceLeft;
    },
  };

  window.Characters = Characters;
})();
