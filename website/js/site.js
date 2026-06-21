// Spectra site — drives the living-desktop renderer: the world deck, the auto-cycle,
// the now-playing HUD, and the page polish. Plain DOM, no deps.
(() => {
  'use strict';

  // The 16 shipped presets, in curated "best first" order. Copy is lifted verbatim
  // from Sources/Presets/BuiltInPresets.swift so the site can't drift from the app.
  const WORLDS = [
    { id:'painting',  name:'Painting',      cat:'Artistic',  glyph:'🎨', tier:'Full', desc:'Impressionist oil brushwork with broken colour and a luminous watercolour wash.' },
    { id:'comic',     name:'Comic Book',    cat:'Artistic',  glyph:'💥', tier:'Full', desc:'Pop-art print: punchy posterised colour and a Ben-Day halftone dot screen.' },
    { id:'cyberpunk', name:'Cyberpunk',     cat:'Cinematic', glyph:'🌃', tier:'Free', desc:'Your desktop as a neon-lit night city: crushed blacks, blooming magenta-cyan light.' },
    { id:'fuji',      name:'Fuji-Film',     cat:'Cinematic', glyph:'📸', tier:'Free', desc:'Warm 2000s disposable-camera look: amber cast, punchy contrast, heavy live grain.' },
    { id:'matrix',    name:'The Matrix',    cat:'Retro',     glyph:'🟩', tier:'Full', desc:'A live hacker terminal: animated code rain over a near-mono green-black world.' },
    { id:'frutiger',  name:'Frutiger Aero', cat:'Retro',     glyph:'🫧', tier:'Full', desc:'Lush nature-tech glass: vivid aqua-greens, clean skies, and glossy bubble bloom.' },
    { id:'crt',       name:'CRT Display',   cat:'Retro',     glyph:'📺', tier:'Full', desc:'The glow and grain of a real phosphor tube: scanlines, shadow mask, persistence.' },
    { id:'vhs',       name:'VHS Tape',      cat:'Retro',     glyph:'📼', tier:'Full', desc:'Magnetic-tape decay live on your desktop: chroma bleed, tracking drift, tape hiss.' },
    { id:'print',     name:'Print Art',     cat:'Artistic',  glyph:'🗾', tier:'Full', desc:'Woodblock print: flat colour fields, crisp key-block lines, and visible washi paper.' },
    { id:'golden',    name:'Golden Hour',   cat:'Cinematic', glyph:'🌅', tier:'Free', desc:'Warm halation glow and golden-hour bloom, the whole desktop lit like magic-hour cinema.' },
    { id:'pencil',    name:'Pencil Sketch', cat:'Artistic',  glyph:'✏️', tier:'Full', desc:'A hand-drawn graphite sketch: contour lines, cross-hatch shading, and warm paper.' },
    { id:'noir',      name:'Noir',          cat:'Cinematic', glyph:'🎬', tier:'Free', desc:'Darkroom-accurate black-and-white built on real film colour science.' },
    { id:'studio',    name:'Studio',        cat:'Utility',   glyph:'🖥️', tier:'Full', desc:'A calibrated display upgrade: deeper blacks, richer midtones, and crisp clarity, all day.' },
    { id:'reading',   name:'Reading',       cat:'Utility',   glyph:'📖', tier:'Full', desc:'Paper-white for your whole screen: lifted dark-UI glare and re-crispened text.' },
    { id:'night',     name:'Night Light',   cat:'Utility',   glyph:'🌙', tier:'Full', desc:'Warm, blue-light-reduced screen for late-night use with a gently dimmed white point.' },
    { id:'crisp',     name:'Crisp Text',    cat:'Utility',   glyph:'🔡', tier:'Full', desc:'Razor-sharp UI text: edge sharpening with no colour change, so small type reads clean.' },
  ];
  const byId = Object.fromEntries(WORLDS.map(w => [w.id, w]));

  // The 14 shipping effect categories with real counts (sum = 169), each mapped to the
  // world that best represents it in the renderer.
  const CATS = [
    { name:'Color', n:26, fx:'cyberpunk' }, { name:'Film', n:16, fx:'golden' },
    { name:'Retro / CRT', n:14, fx:'crt' }, { name:'Noise', n:14, fx:'fuji' },
    { name:'Glitch', n:13, fx:'matrix' },   { name:'VHS', n:12, fx:'vhs' },
    { name:'Pixel', n:12, fx:'comic' },     { name:'Environment', n:12, fx:'frutiger' },
    { name:'Distortion', n:12, fx:'vhs' },  { name:'Artistic', n:11, fx:'painting' },
    { name:'Camcorder', n:10, fx:'vhs' },   { name:'Blur', n:8, fx:'golden' },
    { name:'Sharpen', n:6, fx:'crisp' },    { name:'System / Desktop', n:3, fx:'studio' },
  ];

  const DWELL = 3.8;          // seconds shown per world before auto-advancing
  let idx = 0, paused = false, lastSwitch = 0, deckCards = {};

  function go(id, fromUser){
    const w = byId[id]; if(!w || !window.Spectra) return;
    const moved = window.Spectra.transitionTo(id);
    idx = WORLDS.findIndex(x => x.id === id);
    lastSwitch = performance.now()/1000;
    if(fromUser) paused = true, setPlay();
    paintHud(w); setActive(id);
    return moved;
  }

  function setActive(id){ for(const k in deckCards) deckCards[k].classList.toggle('on', k === id);
    deckCards[id]?.scrollIntoView({ inline:'center', block:'nearest', behavior:'smooth' }); }

  function paintHud(w){
    const hud = document.getElementById('hud'); if(!hud) return;
    hud.querySelector('.hud-glyph').textContent = w.glyph;
    hud.querySelector('.hud-name').textContent = w.name;
    hud.querySelector('.hud-desc').textContent = w.desc;
    const chip = hud.querySelector('.hud-cat'); chip.textContent = w.cat;
    chip.className = 'hud-cat cat-' + w.cat.toLowerCase().split(' ')[0];
    const tier = hud.querySelector('.hud-tier');
    tier.textContent = w.tier === 'Free' ? 'Free tier' : 'Full';
    tier.classList.toggle('full', w.tier !== 'Free');
  }

  const playBtn = () => document.getElementById('play');
  function setPlay(){ const b = playBtn(); if(b){ b.textContent = paused ? '▶' : 'II'; b.setAttribute('aria-label', paused ? 'Resume auto-cycle' : 'Pause auto-cycle'); } }

  function buildDeck(){
    const deck = document.getElementById('deck'); if(!deck) return;
    WORLDS.forEach((w, i) => {
      const b = document.createElement('button');
      b.className = 'world' + (i === 0 ? ' on' : '');
      b.type = 'button'; b.dataset.id = w.id;
      b.innerHTML = `<span class="w-glyph">${w.glyph}</span>
        <span class="w-meta"><b>${w.name}</b><i>${w.cat}</i></span>
        <span class="w-tier ${w.tier === 'Free' ? 'free' : ''}">${w.tier === 'Free' ? 'Free' : '🔒'}</span>`;
      b.addEventListener('click', () => go(w.id, true));
      deck.appendChild(b); deckCards[w.id] = b;
    });
  }

  function wire(){
    buildDeck();
    paintHud(WORLDS[0]);
    if(window.Spectra) { window.Spectra.transitionTo(WORLDS[0].id); window.Spectra.setAmount(0.9); }

    const amt = document.getElementById('amount');
    if(amt) amt.addEventListener('input', () => window.Spectra?.setAmount(amt.value/100));

    playBtn()?.addEventListener('click', () => { paused = !paused; if(!paused) lastSwitch = performance.now()/1000; setPlay(); });
    document.getElementById('prev')?.addEventListener('click', () => go(WORLDS[(idx-1+WORLDS.length)%WORLDS.length].id, true));
    document.getElementById('next')?.addEventListener('click', () => go(WORLDS[(idx+1)%WORLDS.length].id, true));

    // Category grid -> jump the renderer to a representative world.
    const grid = document.getElementById('catGrid');
    if(grid) CATS.forEach(c => {
      const card = document.createElement('button');
      card.className = 'cat'; card.type = 'button';
      card.innerHTML = `<b>${c.name}</b><i>${c.n}</i>`;
      card.addEventListener('click', () => { go(c.fx, true); document.getElementById('top').scrollIntoView({ behavior:'smooth' }); });
      grid.appendChild(card);
    });

    // World-name buttons elsewhere on the page.
    document.querySelectorAll('[data-world]').forEach(el =>
      el.addEventListener('click', () => { go(el.dataset.world, true); document.getElementById('top').scrollIntoView({ behavior:'smooth' }); }));

    requestAnimationFrame(tick);
  }

  function tick(now){
    const t = now/1000;
    const bar = document.getElementById('hudbar');
    if(!paused && !window.Spectra?.busy()){
      const p = Math.min(1, (t - lastSwitch)/DWELL);
      if(bar) bar.style.transform = `scaleX(${p})`;
      if(p >= 1) go(WORLDS[(idx+1)%WORLDS.length].id, false);
    } else if(bar && paused){ bar.style.transform = 'scaleX(0)'; }
    requestAnimationFrame(tick);
  }

  if(window.Spectra) wire();
  else document.addEventListener('spectra-ready', wire, { once:true });

  // Scroll reveals + nav + year.
  const io = new IntersectionObserver(es => es.forEach(e => { if(e.isIntersecting){ e.target.classList.add('in'); io.unobserve(e.target); } }), { threshold:0.12 });
  document.querySelectorAll('.section, .step, .price-card, .feat').forEach(el => { el.classList.add('reveal'); io.observe(el); });
  const nav = document.querySelector('.nav');
  addEventListener('scroll', () => nav?.classList.toggle('scrolled', scrollY > 12));
  const yr = document.getElementById('year'); if(yr) yr.textContent = new Date().getFullYear();
})();
