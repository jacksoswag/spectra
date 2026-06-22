// Spectra cinematic — WebGL engine.
// Takes a 2D "scene" canvas (a desktop / app replica), uploads it, and shades it through
// the current preset world. A preset switch fires a radial beam (the orb's colour)
// expanding from a screen-space origin. Exposes window.Engine.

(() => {
  'use strict';
  const S = window.SPECTRA_SHADERS;
  const VERT = `attribute vec2 aPos; varying vec2 vUv; void main(){ vUv = aPos*0.5+0.5; gl_Position = vec4(aPos,0.0,1.0); }`;

  let gl, programs = {}, composite, buf, sceneTex, fboA, fboB, canvas;
  let cur = 'none', tr = null, amount = 1.0;

  const compile = (type, s) => { const o = gl.createShader(type); gl.shaderSource(o, s); gl.compileShader(o);
    if (!gl.getShaderParameter(o, gl.COMPILE_STATUS)) { console.error('shader', gl.getShaderInfoLog(o), s); return null; } return o; };
  const prog = (fs) => { const p = gl.createProgram(); gl.attachShader(p, compile(gl.VERTEX_SHADER, VERT)); gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p); if (!gl.getProgramParameter(p, gl.LINK_STATUS)) { console.error('link', gl.getProgramInfoLog(p)); return null; } return p; };
  const tex = () => { const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR); return t; };
  const fbo = (w, h) => { const t = tex(); gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    const f = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, f); gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null); return { tex: t, fbo: f }; };
  const quad = (p) => { const loc = gl.getAttribLocation(p, 'aPos'); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0); gl.drawArrays(gl.TRIANGLES, 0, 3); };

  function size() {
    const dpr = Math.min(window.devicePixelRatio || 1, 1.4);
    canvas.width = Math.round(innerWidth * dpr); canvas.height = Math.round(innerHeight * dpr);
    fboA = fbo(canvas.width, canvas.height); fboB = fbo(canvas.width, canvas.height);
  }

  function world(id, target) {
    const p = programs[id] || programs.none;
    gl.bindFramebuffer(gl.FRAMEBUFFER, target ? target.fbo : null);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.useProgram(p);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, sceneTex);
    gl.uniform1i(gl.getUniformLocation(p, 'uTex'), 0);
    gl.uniform2f(gl.getUniformLocation(p, 'uRes'), canvas.width, canvas.height);
    gl.uniform1f(gl.getUniformLocation(p, 'uTime'), Engine.time);
    gl.uniform1f(gl.getUniformLocation(p, 'uAmount'), amount);
    quad(p);
  }

  const Engine = {
    time: 0,
    ok: false,
    preset: () => cur,
    busy: () => !!tr,

    init(glCanvas) {
      canvas = glCanvas;
      gl = canvas.getContext('webgl', { antialias: false, premultipliedAlpha: false, powerPreference: 'high-performance' });
      if (!gl) return false;
      for (const k in S.WORLDS) programs[k] = prog(S.WORLDS[k]);
      composite = prog(S.COMPOSITE);
      buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      sceneTex = tex();
      size(); addEventListener('resize', size);
      this.ok = true; return true;
    },

    setAmount(a) { amount = Math.max(0, Math.min(1, a)); },

    // origin in 0..1 screen space (y from top). instant skips the beam.
    setPreset(id, origin = [0.5, 0.5], instant = false) {
      if (!programs[id] || (id === cur && !tr)) return;
      if (instant) { cur = id; tr = null; return; }
      const col = S.SIGNATURE[id] || [1, 1, 1];
      tr = { from: cur, to: id, origin: [origin[0], 1 - origin[1]], color: col, startT: null, dur: 0.55 };
      cur = id;
    },

    // upload the freshly-drawn scene and render this frame.
    render(sceneCanvas, t) {
      this.time = t;
      gl.bindTexture(gl.TEXTURE_2D, sceneTex);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
      try { gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, sceneCanvas); } catch (e) {}

      if (tr) {
        if (tr.startT === null) tr.startT = t;
        const p = Math.min(1, (t - tr.startT) / tr.dur);
        world(tr.from, fboA); world(tr.to, fboB);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0, 0, canvas.width, canvas.height);
        gl.useProgram(composite);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, fboA.tex); gl.uniform1i(gl.getUniformLocation(composite, 'uFrom'), 0);
        gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, fboB.tex); gl.uniform1i(gl.getUniformLocation(composite, 'uTo'), 1);
        gl.uniform2f(gl.getUniformLocation(composite, 'uRes'), canvas.width, canvas.height);
        gl.uniform1f(gl.getUniformLocation(composite, 'uProg'), p);
        gl.uniform2f(gl.getUniformLocation(composite, 'uOrigin'), tr.origin[0], tr.origin[1]);
        gl.uniform3f(gl.getUniformLocation(composite, 'uColor'), tr.color[0], tr.color[1], tr.color[2]);
        quad(composite);
        if (p >= 1) tr = null;
      } else {
        world(cur, null);
      }
    },
  };

  window.Engine = Engine;
})();
