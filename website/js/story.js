// Spectra cinematic — the story timeline.
// SHOTS play in order and loop. Each shot sets a surface (scene) + preset, a duration,
// per-character keyframes (virtual 1280x720 space), the orb's path, and prop flags the
// director draws (wall, pow, paused bar, magnifier, noir blinds). Choreography is
// authored against window.Rig.POSES. Exposes window.STORY.

(() => {
  'use strict';
  const VW = 1280, VH = 720, G = 600, S = 1.9, FY = G - 30 * S;

  // keyframe + orb-keyframe helpers
  const kf = (t, x, pose, flip = 1, o = {}) => ({ t, world: { x, y: o.y != null ? o.y : FY, s: o.s || S, flip, rot: o.rot || 0 }, pose });
  const ob = (t, x, y, held = null) => ({ t, x, y, held });

  const SHOTS = [
    { name: 'discover', scene: 'spectra', preset: 'none', dur: 9, sub: 'A prism appears on the desktop…', fact: 'Spectra',
      cyan: [kf(0, -80, 'walkA'), kf(.18, 260, 'walkB'), kf(.4, 520, 'walkA'), kf(.55, 560, 'reach'), kf(.7, 560, 'reach'), kf(1, 560, 'reach')],
      magenta: [kf(0, 1360, 'idle', -1), kf(.55, 1200, 'crouch', -1), kf(1, 1160, 'crouch', -1)],
      orb: [ob(0, 640, 300), ob(.7, 640, 300), ob(1, 620, 320)] },

    { name: 'demo-fuji', scene: 'docs', preset: 'fuji', dur: 1.6, sub: 'Cyan tries it — Fuji-Film on a doc.', fact: 'Fuji-Film',
      cyan: [kf(0, 560, 'present'), kf(1, 560, 'present')],
      magenta: [kf(0, 1160, 'crouch', -1), kf(1, 1140, 'crouch', -1)],
      orb: [ob(0, 600, 520, 'cyan'), ob(1, 600, 520, 'cyan')] },

    { name: 'demo-cyber', scene: 'spotify', preset: 'cyberpunk', dur: 1.4, sub: 'Cyberpunk on Spotify.', fact: 'Cyberpunk',
      cyan: [kf(0, 560, 'present'), kf(1, 560, 'present')],
      magenta: [kf(0, 1140, 'crouch', -1), kf(1, 1080, 'crouch', -1)],
      orb: [ob(0, 600, 520, 'cyan'), ob(1, 600, 520, 'cyan')] },

    { name: 'demo-night', scene: 'desktop', preset: 'night', dur: 1.4, sub: 'Night Light on the desktop.', fact: 'Night Light',
      cyan: [kf(0, 560, 'present'), kf(1, 560, 'amazed')],
      magenta: [kf(0, 1080, 'crouch', -1), kf(1, 980, 'crouch', -1)],
      orb: [ob(0, 600, 520, 'cyan'), ob(1, 600, 520, 'cyan')] },

    { name: 'grab', scene: 'desktop', preset: 'none', dur: 1.8, sub: 'Magenta grabs it out of greed!', fact: '',
      cyan: [kf(0, 560, 'amazed'), kf(.6, 560, 'recoil'), kf(1, 600, 'recoil')],
      magenta: [kf(0, 980, 'runA', -1), kf(.5, 720, 'runB', -1), kf(.72, 640, 'grab', -1), kf(1, 660, 'grab', -1)],
      orb: [ob(0, 600, 520, 'cyan'), ob(.72, 650, 515, 'magenta'), ob(1, 680, 510, 'magenta')] },

    { name: 'crt', scene: 'youtube', preset: 'crt', dur: 2.4, sub: 'CRT — the warp leaves them dizzy.', fact: '16 worlds',
      cyan: [kf(0, 600, 'recoil'), kf(.4, 500, 'dodge'), kf(.75, 540, 'crouch'), kf(1, 540, 'idle')],
      magenta: [kf(0, 680, 'grab', -1), kf(.5, 760, 'dodge', -1), kf(1, 720, 'idle', -1)],
      orb: [ob(0, 700, 510, 'magenta'), ob(1, 740, 510, 'magenta')] },

    { name: 'comic', scene: 'photos', preset: 'comic', dur: 2.6, sub: 'Comic — a wacky brawl. POW!', fact: '169 effects',
      props: { pow: [.42, .58] },
      cyan: [kf(0, 380, 'runA'), kf(.4, 620, 'punch'), kf(.52, 620, 'punch'), kf(.7, 540, 'recoil'), kf(1, 540, 'idle')],
      magenta: [kf(0, 860, 'idle', -1), kf(.4, 720, 'recoil', -1), kf(.62, 700, 'punch', -1), kf(1, 780, 'idle', -1)],
      orb: [ob(0, 740, 500, 'magenta'), ob(.5, 660, 360), ob(1, 720, 500, 'magenta')] },

    { name: 'painting', scene: 'figma', preset: 'painting', dur: 2.8, sub: 'Painting — Magenta paints a wall to block Cyan.', fact: 'build your own',
      props: { wall: [.2, .55, 640] },
      cyan: [kf(0, 340, 'runA'), kf(.46, 560, 'recoil'), kf(.62, 520, 'crouch'), kf(1, 500, 'idle')],
      magenta: [kf(0, 780, 'paint', -1), kf(.5, 780, 'paint', -1), kf(1, 780, 'present', -1)],
      orb: [ob(0, 820, 500, 'magenta'), ob(1, 820, 500, 'magenta')] },

    { name: 'matrix', scene: 'terminal', preset: 'matrix', dur: 2.8, sub: 'Matrix — code-rain hits Magenta; the orb drops.', fact: 'no subscription',
      cyan: [kf(0, 470, 'dodge'), kf(.5, 520, 'dodge'), kf(.74, 620, 'grab'), kf(1, 600, 'grab')],
      magenta: [kf(0, 780, 'present', -1), kf(.4, 780, 'recoil', -1), kf(.6, 820, 'recoil', -1), kf(1, 860, 'crouch', -1)],
      orb: [ob(0, 800, 500, 'magenta'), ob(.5, 770, 560), ob(.64, 680, 600), ob(.78, 620, 540, 'cyan'), ob(1, 600, 520, 'cyan')] },

    { name: 'golden', scene: 'photos', preset: 'golden', dur: 2.6, sub: 'Golden Hour — Cyan is mesmerised; Magenta steals it back.', fact: 'multi-monitor',
      cyan: [kf(0, 600, 'amazed'), kf(.62, 600, 'amazed'), kf(.82, 600, 'recoil'), kf(1, 620, 'recoil')],
      magenta: [kf(0, 940, 'crouch', -1), kf(.5, 740, 'walkA', -1), kf(.82, 660, 'grab', -1), kf(1, 650, 'grab', -1)],
      orb: [ob(0, 600, 520, 'cyan'), ob(.82, 660, 515, 'magenta'), ob(1, 670, 510, 'magenta')] },

    { name: 'vhs', scene: 'youtube', preset: 'vhs', dur: 3.0, sub: 'VHS — Magenta hits pause and freezes Cyan.', fact: 'so real it can’t be screen-captured',
      props: { paused: [.5, 1] },
      cyan: [kf(0, 500, 'runA'), kf(.3, 600, 'jump'), kf(.46, 650, 'jump'), kf(.5, 660, 'frozen'), kf(1, 660, 'frozen')],
      magenta: [kf(0, 760, 'recoil', -1), kf(.46, 800, 'present', -1), kf(.62, 900, 'walkB', -1), kf(1, 1180, 'walkA', -1)],
      orb: [ob(0, 700, 500, 'magenta'), ob(.62, 900, 500, 'magenta'), ob(1, 1180, 500, 'magenta')] },

    { name: 'noir', scene: 'desktop', preset: 'noir', dur: 4.2, sub: 'Noir — Cyan turns detective and searches.', fact: 'Apple Silicon · macOS 15+',
      props: { blinds: true, magnifier: 'cyan' },
      cyan: [kf(0, 660, 'idle'), kf(.18, 660, 'detective'), kf(.5, 500, 'detective'), kf(.78, 820, 'detective', -1), kf(1, 820, 'detective', -1)],
      magenta: [kf(0, 1340, 'idle', -1), kf(1, 1380, 'idle', -1)],
      orb: [ob(0, 1340, 500, 'magenta'), ob(1, 1400, 500, 'magenta')] },

    { name: 'fade', scene: 'spectra', preset: 'none', dur: 2.6, sub: '', fact: '$9.99 — four worlds free',
      props: { fade: true },
      cyan: [kf(0, 820, 'walkA', -1), kf(1, -80, 'walkB', -1)],
      magenta: [kf(0, 1400, 'idle', -1), kf(1, 1440, 'idle', -1)],
      orb: [ob(0, 1400, 500, 'magenta'), ob(1, 1460, 500, 'magenta')] },
  ];

  window.STORY = { SHOTS, VW, VH, G, S };
})();
