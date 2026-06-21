// Site interactions: builds the controls, wires them to the live demo, and adds the
// scroll/marquee polish. Plain DOM, no deps.
(() => {
  'use strict';

  const CHIPS = [
    { id: 'crt', label: 'CRT' },
    { id: 'vhs', label: 'VHS' },
    { id: 'glitch', label: 'Glitch' },
    { id: 'oil', label: 'Oil Paint' },
    { id: 'dream', label: 'Dreamy' },
    { id: 'gameboy', label: 'Game Boy' },
    { id: 'comic', label: 'Comic' },
    { id: 'none', label: 'Off' },
  ];

  // The 14 shipping categories, each mapped to the demo effect that best stands in.
  const CATS = [
    { name: 'Color', n: 26, fx: 'dream' },
    { name: 'Sharpen', n: 6, fx: 'none' },
    { name: 'Blur', n: 8, fx: 'dream' },
    { name: 'Distortion', n: 12, fx: 'glitch' },
    { name: 'Retro / CRT', n: 14, fx: 'crt' },
    { name: 'VHS', n: 12, fx: 'vhs' },
    { name: 'Camcorder', n: 10, fx: 'vhs' },
    { name: 'Film', n: 16, fx: 'dream' },
    { name: 'Noise', n: 14, fx: 'glitch' },
    { name: 'Pixel', n: 12, fx: 'gameboy' },
    { name: 'Glitch', n: 13, fx: 'glitch' },
    { name: 'Environment', n: 11, fx: 'dream' },
    { name: 'Artistic', n: 11, fx: 'oil' },
    { name: 'System / Desktop', n: 3, fx: 'none' },
  ];

  let userTouched = false;
  let cycleTimer = null;

  function setActiveChip(id) {
    document.querySelectorAll('.chip').forEach((c) => c.classList.toggle('on', c.dataset.fx === id));
  }

  function selectEffect(id, fromUser) {
    if (!window.Spectra) return;
    window.Spectra.setEffect(id);
    setActiveChip(id);
    if (fromUser) { userTouched = true; if (cycleTimer) clearInterval(cycleTimer); }
  }

  function wire() {
    // Effect chips
    const chips = document.getElementById('chips');
    if (chips) {
      CHIPS.forEach((c, i) => {
        const b = document.createElement('button');
        b.className = 'chip' + (i === 0 ? ' on' : '');
        b.dataset.fx = c.id;
        b.textContent = c.label;
        b.setAttribute('role', 'tab');
        b.addEventListener('click', () => selectEffect(c.id, true));
        chips.appendChild(b);
      });
    }

    // Category grid (clicking loads the effect and scrolls to the demo)
    const grid = document.getElementById('catGrid');
    if (grid) {
      CATS.forEach((cat) => {
        const card = document.createElement('button');
        card.className = 'cat';
        card.innerHTML = `<b>${cat.name}</b><i>${cat.n}</i>`;
        card.addEventListener('click', () => {
          selectEffect(cat.fx, true);
          document.getElementById('top').scrollIntoView({ behavior: 'smooth' });
        });
        grid.appendChild(card);
      });
    }

    // World cards
    document.querySelectorAll('.world-card').forEach((card) => {
      card.addEventListener('click', () => {
        selectEffect(card.dataset.effect, true);
        document.getElementById('top').scrollIntoView({ behavior: 'smooth' });
      });
    });

    // Intensity + wipe
    const amount = document.getElementById('amount');
    if (amount) amount.addEventListener('input', () => { userTouched = true; window.Spectra?.setAmount(amount.value / 100); });
    const wipe = document.getElementById('wipe');
    if (wipe) wipe.addEventListener('input', () => window.Spectra?.setSplit(wipe.value / 100));

    // Camera
    const cam = document.getElementById('cam');
    if (cam) {
      let on = false;
      cam.addEventListener('click', async () => {
        on = !on;
        cam.classList.toggle('on', on);
        cam.textContent = on ? 'Stop camera' : 'Shade my camera';
        const ok = await window.Spectra?.toggleCamera(on);
        if (on && !ok) { on = false; cam.classList.remove('on'); cam.textContent = 'Camera blocked'; }
      });
    }

    // Gentle auto-cycle through effects until the visitor takes over.
    const order = ['crt', 'vhs', 'glitch', 'oil', 'dream', 'gameboy', 'comic'];
    let k = 0;
    cycleTimer = setInterval(() => {
      if (userTouched) return;
      k = (k + 1) % order.length;
      window.Spectra?.setEffect(order[k]);
      setActiveChip(order[k]);
    }, 2600);
  }

  if (window.Spectra) wire();
  else document.addEventListener('spectra-ready', wire, { once: true });

  // Scroll reveals
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
  }, { threshold: 0.12 });
  document.querySelectorAll('.section, .step, .price-card, .world-card, .cat').forEach((el) => {
    el.classList.add('reveal'); io.observe(el);
  });

  // Nav shadow on scroll + year
  const nav = document.querySelector('.nav');
  window.addEventListener('scroll', () => nav?.classList.toggle('scrolled', window.scrollY > 12));
  const year = document.getElementById('year');
  if (year) year.textContent = new Date().getFullYear();
})();
