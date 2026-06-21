// Spectra live shader playground.
// Renders a mock macOS desktop (or your camera) to a texture, then post-processes it
// with real WebGL fragment shaders that mirror the app's effects. Vanilla, no deps.

(() => {
  'use strict';

  const VERT = `
    attribute vec2 aPos;
    varying vec2 vUv;
    void main() {
      vUv = aPos * 0.5 + 0.5;
      gl_Position = vec4(aPos, 0.0, 1.0);
    }`;

  // Each effect is a fragment shader post-processing uTex.
  // Uniforms: uTex, uRes, uTime, uAmount (0..1), uSplit (before/after wipe x in 0..1).
  const HEAD = `
    precision highp float;
    varying vec2 vUv;
    uniform sampler2D uTex;
    uniform vec2 uRes;
    uniform float uTime;
    uniform float uAmount;
    uniform float uSplit;
    float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
    float luma(vec3 c){ return dot(c, vec3(0.299, 0.587, 0.114)); }
  `;

  const MIX = `
    vec3 finish(vec3 fx, vec3 src){
      // before/after wipe: left of uSplit shows source, right shows the effect
      float side = step(uSplit, vUv.x);
      return mix(src, mix(src, fx, uAmount), side);
    }`;

  const EFFECTS = {
    none: HEAD + MIX + `
      void main(){ vec3 c = texture2D(uTex, vUv).rgb; gl_FragColor = vec4(finish(c, c), 1.0); }`,

    crt: HEAD + MIX + `
      void main(){
        vec2 uv = vUv;
        vec2 cc = uv - 0.5;
        float warp = 0.18 * uAmount;
        uv = uv + cc * dot(cc, cc) * warp;            // barrel
        vec3 src = texture2D(uTex, vUv).rgb;
        if (uv.x<0.0||uv.x>1.0||uv.y<0.0||uv.y>1.0){ gl_FragColor=vec4(finish(vec3(0.02),src),1.0); return; }
        vec3 c = texture2D(uTex, uv).rgb;
        float sl = 0.5 + 0.5 * sin(uv.y * uRes.y * 1.2);   // scanlines
        c *= mix(1.0, 0.75 + 0.25*sl, uAmount);
        float m = mod(gl_FragCoord.x, 3.0);                 // aperture mask
        vec3 mask = vec3(m<1.0?1.1:0.85, (m>=1.0&&m<2.0)?1.1:0.85, m>=2.0?1.1:0.85);
        c *= mix(vec3(1.0), mask, uAmount);
        float vig = smoothstep(1.1, 0.3, length(cc));       // vignette
        c *= mix(1.0, vig, uAmount*0.9);
        c += 0.04 * uAmount;                                // tube glow lift
        gl_FragColor = vec4(finish(c, src), 1.0);
      }`,

    vhs: HEAD + MIX + `
      void main(){
        vec2 uv = vUv;
        float t = uTime;
        float tear = step(0.985, fract(sin(floor(uv.y*60.0)+floor(t*2.0))*9.0));
        float wob = (hash(vec2(floor(uv.y*80.0), floor(t*8.0)))-0.5) * 0.02 * uAmount;
        uv.x += wob + tear * 0.04 * uAmount;
        float off = 0.006 * uAmount;
        float r = texture2D(uTex, uv + vec2(off,0.0)).r;     // chroma bleed
        float g = texture2D(uTex, uv).g;
        float b = texture2D(uTex, uv - vec2(off,0.0)).b;
        vec3 c = vec3(r,g,b);
        c = mix(c, vec3(luma(c)), 0.15*uAmount);             // desaturate
        float n = hash(uv*uRes + t) - 0.5;                   // tape noise
        c += n * 0.12 * uAmount;
        c *= mix(1.0, 0.85 + 0.15*sin(uv.y*uRes.y*0.7), uAmount); // soft lines
        vec3 src = texture2D(uTex, vUv).rgb;
        gl_FragColor = vec4(finish(c, src), 1.0);
      }`,

    glitch: HEAD + MIX + `
      void main(){
        vec2 uv = vUv;
        float band = floor(uv.y * 24.0);
        float trig = step(0.7, hash(vec2(band, floor(uTime*6.0))));
        float shift = (hash(vec2(band, floor(uTime*6.0)+3.0)) - 0.5) * 0.25 * uAmount * trig;
        uv.x = fract(uv.x + shift);
        float a = 0.015 * uAmount * (0.5 + trig);
        float r = texture2D(uTex, uv + vec2(a,0.0)).r;
        float g = texture2D(uTex, uv).g;
        float b = texture2D(uTex, uv - vec2(a,0.0)).b;
        vec3 c = vec3(r,g,b);
        c += trig * uAmount * 0.10 * vec3(hash(uv+uTime), hash(uv+7.0), hash(uv+13.0));
        vec3 src = texture2D(uTex, vUv).rgb;
        gl_FragColor = vec4(finish(c, src), 1.0);
      }`,

    oil: HEAD + MIX + `
      // Painterly: directional smear + posterize + ink edges (a cheap oil look).
      void main(){
        vec2 px = 1.0 / uRes;
        vec3 sum = vec3(0.0); float wsum = 0.0;
        for(int i=-3;i<=3;i++){
          for(int j=-3;j<=3;j++){
            vec2 o = vec2(float(i), float(j));
            float w = exp(-dot(o,o)/8.0);
            sum += texture2D(uTex, vUv + o*px*(1.0+2.0*uAmount)).rgb * w;
            wsum += w;
          }
        }
        vec3 paint = sum / wsum;
        float bands = mix(24.0, 7.0, uAmount);
        paint = floor(paint * bands) / bands;               // posterize into cells
        paint = mix(texture2D(uTex,vUv).rgb, paint, uAmount);
        // ink: darken where luminance changes fast
        float lx = luma(texture2D(uTex, vUv+vec2(px.x,0)).rgb) - luma(texture2D(uTex, vUv-vec2(px.x,0)).rgb);
        float ly = luma(texture2D(uTex, vUv+vec2(0,px.y)).rgb) - luma(texture2D(uTex, vUv-vec2(0,px.y)).rgb);
        float edge = smoothstep(0.12, 0.4, length(vec2(lx,ly)));
        paint *= 1.0 - edge * uAmount * 0.85;
        vec3 src = texture2D(uTex, vUv).rgb;
        gl_FragColor = vec4(finish(paint, src), 1.0);
      }`,

    dream: HEAD + MIX + `
      // Bloom/halation + warm cinematic grade.
      void main(){
        vec2 px = 1.0/uRes;
        vec3 glow = vec3(0.0);
        for(int i=-4;i<=4;i++){
          for(int j=-4;j<=4;j++){
            vec2 o = vec2(float(i),float(j));
            vec3 s = texture2D(uTex, vUv + o*px*2.5).rgb;
            glow += max(s - 0.66, 0.0) * exp(-dot(o,o)/14.0);
          }
        }
        vec3 c = texture2D(uTex, vUv).rgb;
        c += glow * 0.45 * uAmount;
        c = mix(c, c*vec3(1.08,1.0,0.92)+vec3(0.02,0.0,0.03), uAmount); // warm tilt
        c = pow(c, vec3(mix(1.0, 0.92, uAmount)));
        vec3 src = texture2D(uTex, vUv).rgb;
        gl_FragColor = vec4(finish(c, src), 1.0);
      }`,

    gameboy: HEAD + MIX + `
      void main(){
        float px = mix(220.0, 64.0, uAmount);
        vec2 uv = floor(vUv * px) / px;                      // pixelate
        vec3 s = texture2D(uTex, uv).rgb;
        float l = luma(s);
        float d = (hash(floor(vUv*px)) - 0.5) * 0.12;        // dither
        l = clamp(l + d, 0.0, 1.0);
        vec3 p0=vec3(0.06,0.22,0.06), p1=vec3(0.19,0.38,0.11), p2=vec3(0.55,0.67,0.06), p3=vec3(0.78,0.86,0.18);
        vec3 gb = l<0.25?p0 : l<0.5?p1 : l<0.75?p2 : p3;     // 4-tone DMG palette
        gl_FragColor = vec4(finish(mix(s, gb, uAmount), s), 1.0);
      }`,

    comic: HEAD + MIX + `
      // Posterize + Ben-Day halftone in shadows + bold ink edges.
      void main(){
        vec2 px = 1.0/uRes;
        vec3 c = texture2D(uTex, vUv).rgb;
        vec3 q = floor(c * 5.0) / 5.0;                       // flat ink colours
        float l = luma(q);
        vec2 g = vUv * uRes;
        float dots = sin(g.x*0.9)*sin(g.y*0.9);
        float halftone = step(l*2.0 - 0.6, dots);            // dots in darks
        q *= mix(1.0, mix(0.6, 1.0, halftone), uAmount*(1.0-l));
        float lx = luma(texture2D(uTex,vUv+vec2(px.x,0)).rgb) - luma(texture2D(uTex,vUv-vec2(px.x,0)).rgb);
        float ly = luma(texture2D(uTex,vUv+vec2(0,px.y)).rgb) - luma(texture2D(uTex,vUv-vec2(0,px.y)).rgb);
        float edge = smoothstep(0.1, 0.35, length(vec2(lx,ly)));
        q *= 1.0 - edge*uAmount;
        gl_FragColor = vec4(finish(mix(c,q,uAmount), c), 1.0);
      }`,
  };

  // --- WebGL helpers -------------------------------------------------------
  function compile(gl, type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      console.error(gl.getShaderInfoLog(s), src); return null;
    }
    return s;
  }
  function program(gl, fs) {
    const p = gl.createProgram();
    gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, VERT));
    gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) { console.error(gl.getProgramInfoLog(p)); return null; }
    return p;
  }

  // --- Mock desktop scene (drawn to a 2D canvas, used as the input texture) -
  function makeScene() {
    const c = document.createElement('canvas');
    c.width = 1280; c.height = 800;
    const x = c.getContext('2d');
    function draw(t) {
      const W = c.width, H = c.height;
      // wallpaper: animated spectral gradient
      const g = x.createLinearGradient(0, 0, W, H);
      const a = (Math.sin(t * 0.3) * 0.5 + 0.5);
      g.addColorStop(0, `hsl(${260 + a * 30}, 80%, 22%)`);
      g.addColorStop(0.5, `hsl(${300 + a * 40}, 75%, 30%)`);
      g.addColorStop(1, `hsl(${190 + a * 30}, 85%, 28%)`);
      x.fillStyle = g; x.fillRect(0, 0, W, H);
      // soft light blobs
      for (let i = 0; i < 5; i++) {
        const bx = W * (0.2 + 0.15 * i) + Math.sin(t * 0.5 + i) * 40;
        const by = H * (0.3 + 0.1 * (i % 3)) + Math.cos(t * 0.4 + i) * 30;
        const rg = x.createRadialGradient(bx, by, 0, bx, by, 260);
        rg.addColorStop(0, ['#ff3df0', '#8b5cff', '#2fd9ff', '#b6ff3d', '#ffd23d'][i] + '55');
        rg.addColorStop(1, '#0000');
        x.fillStyle = rg; x.fillRect(0, 0, W, H);
      }
      // menu bar
      x.fillStyle = 'rgba(10,8,20,0.55)'; x.fillRect(0, 0, W, 34);
      x.fillStyle = '#fff'; x.font = '600 16px Inter, system-ui, sans-serif';
      x.fillText('  Spectra  File  Edit  View', 18, 23);
      x.textAlign = 'right'; x.fillText('100%  Fri 9:41', W - 18, 23); x.textAlign = 'left';
      // a frosted dark window (dark mode reads better and won't blow out under bloom)
      roundRect(x, 150, 150, 560, 420, 18); x.fillStyle = 'rgba(20,15,38,0.82)'; x.fill();
      roundRect(x, 150, 150, 560, 46, 18); x.fillStyle = 'rgba(34,26,60,0.92)'; x.fill();
      ['#ff5f57', '#febc2e', '#28c840'].forEach((col, i) => {
        x.beginPath(); x.arc(178 + i * 24, 173, 7, 0, 7); x.fillStyle = col; x.fill();
      });
      x.fillStyle = '#f4f2ff';
      x.font = '700 26px "Space Grotesk", Inter, sans-serif';
      x.fillText('Your whole desktop,', 184, 250);
      x.fillStyle = '#9b7bff'; x.fillText('shaded in real time.', 184, 288);
      x.fillStyle = '#a39fc4'; x.font = '400 16px Inter, sans-serif';
      ['Capture every display on the GPU.', 'Stack 169 effects. Build your own.', 'Click-through overlay over everything.'].forEach((s, i) => x.fillText('•  ' + s, 184, 336 + i * 30));
      // second floating window (dark)
      roundRect(x, 740, 330, 380, 300, 16); x.fillStyle = 'rgba(16,12,31,0.95)'; x.fill();
      x.fillStyle = '#b6ff3d'; x.font = '600 15px "Space Grotesk", monospace';
      x.fillText('● rec  00:09:41', 766, 372);
      x.fillStyle = '#a39fc4'; x.font = '400 13px Inter, sans-serif';
      ['CRT', 'VHS', 'Glitch', 'Oil paint', 'Game Boy'].forEach((s, i) => x.fillText('▸ ' + s, 766, 410 + i * 28));
      // dock
      const dw = 520, dx = (W - dw) / 2, dy = H - 92;
      roundRect(x, dx, dy, dw, 72, 20); x.fillStyle = 'rgba(245,244,255,0.18)'; x.fill();
      const cols = ['#ff3df0', '#8b5cff', '#2fd9ff', '#b6ff3d', '#ffd23d', '#ff8a3d', '#3dffd2'];
      cols.forEach((col, i) => { roundRect(x, dx + 22 + i * 70, dy + 12, 48, 48, 12); x.fillStyle = col; x.fill(); });
    }
    function roundRect(x, X, Y, W, H, r) {
      x.beginPath(); x.moveTo(X + r, Y);
      x.arcTo(X + W, Y, X + W, Y + H, r); x.arcTo(X + W, Y + H, X, Y + H, r);
      x.arcTo(X, Y + H, X, Y, r); x.arcTo(X, Y, X + W, Y, r); x.closePath();
    }
    return { canvas: c, draw };
  }

  // --- Boot ----------------------------------------------------------------
  function init() {
    const canvas = document.getElementById('demo');
    if (!canvas) return;
    const gl = canvas.getContext('webgl', { antialias: true, premultipliedAlpha: false });
    if (!gl) { canvas.closest('.demo-stage')?.classList.add('no-gl'); return; }

    const programs = {};
    for (const k in EFFECTS) programs[k] = program(gl, EFFECTS[k]);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);

    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

    const scene = makeScene();
    let video = null;     // optional webcam input
    const state = { effect: 'crt', amount: 0.85, split: 0.0, start: performance.now() };

    function resize() {
      const r = canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(r.width * dpr);
      canvas.height = Math.round(r.height * dpr);
    }
    window.addEventListener('resize', resize); resize();

    function frame(now) {
      const t = (now - state.start) / 1000;
      let source = scene.canvas;
      if (video && video.readyState >= 2) source = video;
      else scene.draw(t);

      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
      try { gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, source); } catch (e) {}

      const p = programs[state.effect] || programs.none;
      gl.useProgram(p);
      const loc = gl.getAttribLocation(p, 'aPos');
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1i(gl.getUniformLocation(p, 'uTex'), 0);
      gl.uniform2f(gl.getUniformLocation(p, 'uRes'), canvas.width, canvas.height);
      gl.uniform1f(gl.getUniformLocation(p, 'uTime'), t);
      gl.uniform1f(gl.getUniformLocation(p, 'uAmount'), state.amount);
      gl.uniform1f(gl.getUniformLocation(p, 'uSplit'), state.split);
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);

    // expose controls for site.js
    window.Spectra = {
      setEffect: (e) => { if (programs[e]) state.effect = e; },
      setAmount: (a) => { state.amount = Math.max(0, Math.min(1, a)); },
      setSplit: (s) => { state.split = Math.max(0, Math.min(1, s)); },
      effects: Object.keys(EFFECTS),
      toggleCamera: async (on) => {
        if (on) {
          try {
            const s = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user' }, audio: false });
            video = document.createElement('video');
            video.srcObject = s; video.muted = true; video.playsInline = true; await video.play();
            return true;
          } catch (e) { return false; }
        } else {
          if (video && video.srcObject) video.srcObject.getTracks().forEach((t) => t.stop());
          video = null; return false;
        }
      },
    };
    document.dispatchEvent(new Event('spectra-ready'));
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
