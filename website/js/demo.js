// Spectra — the living desktop.
// One full-viewport WebGL renderer draws a believable macOS desktop to a texture,
// then re-shades it live through the app's 16 real preset worlds. Switching worlds
// fires a prism-dispersion sweep (Spectra splits white light into a spectrum).
// Vanilla WebGL, no deps. Exposes window.Spectra for the page UI.

(() => {
  'use strict';

  const VERT = `
    attribute vec2 aPos;
    varying vec2 vUv;
    void main(){ vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos, 0.0, 1.0); }`;

  // Shared header: uniforms + helpers every world shader can use.
  const HEAD = `
    precision highp float;
    varying vec2 vUv;
    uniform sampler2D uTex;   // the mock-desktop texture
    uniform vec2  uRes;       // output resolution (px)
    uniform float uTime;      // seconds
    uniform float uAmount;    // global intensity 0..1 (the app's universal strength)
    const float PI = 3.14159265;
    float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
    float luma(vec3 c){ return dot(c, vec3(0.299, 0.587, 0.114)); }
    vec3  sat(vec3 c, float s){ return clamp(mix(vec3(luma(c)), c, s), 0.0, 1.0); }
    vec3  src(){ return texture2D(uTex, vUv).rgb; }
    // soft blurred bright-pass (bloom / halation source). 5x5, stride in px.
    vec3 glow(vec2 uv, float thr, float stride){
      vec2 px = stride / uRes;
      vec3 s = vec3(0.0); float w = 0.0;
      for(int i=-2;i<=2;i++){ for(int j=-2;j<=2;j++){
        vec2 o = vec2(float(i), float(j));
        float k = exp(-dot(o,o)/4.0);
        s += max(texture2D(uTex, uv + o*px).rgb - thr, 0.0) * k; w += k;
      }}
      return s / w;
    }
    float sobel(vec2 uv){
      vec2 px = 1.0 / uRes;
      float l00=luma(texture2D(uTex,uv+px*vec2(-1.,-1.)).rgb), l01=luma(texture2D(uTex,uv+px*vec2(0.,-1.)).rgb), l02=luma(texture2D(uTex,uv+px*vec2(1.,-1.)).rgb);
      float l10=luma(texture2D(uTex,uv+px*vec2(-1.,0.)).rgb),                                                     l12=luma(texture2D(uTex,uv+px*vec2(1.,0.)).rgb);
      float l20=luma(texture2D(uTex,uv+px*vec2(-1.,1.)).rgb), l21=luma(texture2D(uTex,uv+px*vec2(0.,1.)).rgb),  l22=luma(texture2D(uTex,uv+px*vec2(1.,1.)).rgb);
      float gx = (l02+2.0*l12+l22)-(l00+2.0*l10+l20);
      float gy = (l20+2.0*l21+l22)-(l00+2.0*l01+l02);
      return length(vec2(gx,gy));
    }
    // 4-stop gradient map by luminance.
    vec3 grad4(float t, vec3 a, vec3 b, vec3 c, vec3 d, float pb, float pc){
      if(t < pb) return mix(a, b, t/pb);
      if(t < pc) return mix(b, c, (t-pb)/(pc-pb));
      return mix(c, d, (t-pc)/(1.0-pc));
    }
    vec4 out3(vec3 fx){ return vec4(clamp(mix(src(), fx, uAmount), 0.0, 1.0), 1.0); }
  `;

  // --- The 16 worlds (faithful to Sources/Presets/BuiltInPresets.swift) --------
  const WORLDS = {
    golden: HEAD + `void main(){               // Golden Hour: bloom + halation + golden grade
      vec3 c = src();
      c += glow(vUv, 0.6, 2.6) * 0.6;
      c += glow(vUv, 0.6, 5.0) * vec3(0.20,0.10,0.04);       // warm halation ring
      c.r *= 1.06; c.b *= 0.93; c += vec3(0.02,0.01,-0.01);  // temperature + brightness
      float leak = smoothstep(0.75,1.5,vUv.x+vUv.y) * (0.55+0.45*sin(uTime*0.25));
      c += leak * vec3(0.16,0.07,0.02);                      // light leak
      gl_FragColor = out3(c);
    }`,

    fuji: HEAD + `void main(){                 // Fuji-Film: amber disposable cam, heavy colour grain, black dust
      vec3 c = src();
      c.r *= 1.06; c.b *= 0.92;                              // amber cast
      c = (c-0.5)*1.14 + 0.5 + 0.015;                        // contrast + lifted blacks
      c.g += 0.025 * (1.0 - abs(luma(c)-0.5)*2.0);           // faint green midtone (cheap C-41)
      c = sat(c, 1.20);
      c += glow(vUv, 0.70, 3.0) * vec3(0.10,0.06,0.02);      // warm flash halation
      vec3 gr = vec3(hash(vUv*uRes+uTime), hash(vUv*uRes+uTime+7.0), hash(vUv*uRes+uTime+13.0)) - 0.5;
      c += gr * 0.13;                                        // live colour grain
      float dust = step(0.9965, hash(floor(vUv*vec2(240.0,150.0))+floor(uTime*7.0)));
      c *= 1.0 - dust*0.55;                                  // sparse black debris
      gl_FragColor = out3(c);
    }`,

    noir: HEAD + `void main(){                 // Noir: green-weighted Tri-X B&W + selenium split + halation
      vec3 s = src();
      float g = dot(s, vec3(0.30,0.62,0.08));                // Tri-X channel mix
      g = (g-0.5)*1.39 + 0.5 - 0.02;                         // tone curve
      vec3 c = vec3(g);
      c += (1.0-g)*vec3(-0.03,0.0,0.05);                     // cool selenium shadows
      c += g*vec3(0.02,0.01,-0.04);                          // warm-paper highlights
      c += glow(vUv, 0.62, 3.2) * vec3(0.26,0.15,0.10);      // halation
      c += (hash(vUv*uRes)-0.5)*0.10;                        // static grain
      gl_FragColor = out3(c);
    }`,

    cyberpunk: HEAD + `void main(){            // Cyberpunk: crushed blacks, magenta/cyan dual-tone, bloom
      vec3 c = src();
      c = max(c-0.06, 0.0)/0.94;                             // black point
      c = (c-0.5)*1.32 + 0.5;                                // contrast
      c = sat(c, 1.45);                                      // vibrance
      float L = luma(c);
      vec3 gm = grad4(L,
        vec3(0.02,0.05,0.09), vec3(0.28,0.10,0.30),
        vec3(0.85,0.18,0.55), vec3(0.55,0.92,1.00), 0.45, 0.78);
      c = mix(c, gm, 0.55);
      c += glow(vUv, 0.55, 3.4) * 0.75;
      gl_FragColor = out3(c);
    }`,

    crt: HEAD + `void main(){                  // CRT Display: curvature, scanlines, shadow mask, vignette, phosphor glow
      vec2 uv = vUv; vec2 cc = uv-0.5;
      uv += cc * dot(cc,cc) * 0.12;                          // barrel
      if(uv.x<0.0||uv.x>1.0||uv.y<0.0||uv.y>1.0){ gl_FragColor = out3(vec3(0.02)); return; }
      vec3 c = texture2D(uTex, uv).rgb;
      c += glow(uv, 0.45, 2.2) * 0.5;                        // phosphor bloom/persistence
      float sl = 0.78 + 0.22*sin(uv.y*uRes.y*1.1);           // scanlines
      c *= sl;
      float m = mod(gl_FragCoord.x, 3.0);                    // shadow mask
      c *= (m<1.0)?vec3(1.08,0.9,0.9):(m<2.0)?vec3(0.9,1.08,0.9):vec3(0.9,0.9,1.08);
      c *= smoothstep(1.25, 0.35, length(cc));               // vignette
      c += 0.03;
      gl_FragColor = out3(c);
    }`,

    vhs: HEAD + `void main(){                  // VHS Tape: warm cast, chroma smear, tracking drift, hiss
      vec2 uv = vUv;
      float trk = sin((uv.y + uTime*0.2)*8.0);
      uv.x += (hash(vec2(floor(uv.y*90.0), floor(uTime*8.0)))-0.5)*0.012 + step(0.93,trk)*0.01;
      vec3 c;                                                // chroma lags left of bright regions
      c.r = texture2D(uTex, uv + vec2(0.010,0.0)).r;
      c.g = texture2D(uTex, uv).g;
      c.b = texture2D(uTex, uv - vec2(0.006,0.0)).b;
      c.r += texture2D(uTex, uv + vec2(0.018,0.0)).r * 0.25; // smear trail
      c.r = min(c.r, 1.0);
      c.r *= 1.07; c.b *= 0.95;                              // warm tape cast
      c = sat(c, 1.18);
      c += (hash(uv*uRes + uTime)-0.5)*0.10;                 // hiss
      c *= 0.9 + 0.1*sin(uv.y*uRes.y*0.6);
      gl_FragColor = out3(c);
    }`,

    matrix: HEAD + `void main(){               // The Matrix: green-black world + falling code rain
      vec3 s = src(); float L = luma(s);
      vec3 c = vec3(0.0, L, L*0.35);
      c = (c-0.5)*1.3 + 0.5; c.g = max(c.g-0.06, 0.0);
      c = sat(c, 0.5);                                       // near-mono
      float cols = 64.0;
      float col = floor(vUv.x*cols);
      float spd = 0.5 + hash(vec2(col,1.0))*1.3;
      float head = fract(vUv.y*1.0 - uTime*spd*0.18 + hash(vec2(col,3.0)));
      float bright = smoothstep(0.0,0.05,head) * smoothstep(0.6,0.0,head);
      float glyph = step(0.45, hash(floor(vec2(vUv.x*cols, vUv.y*44.0 + floor(uTime*spd*9.0)))));
      c += bright*glyph*vec3(0.25,1.0,0.45);                 // bright glyph heads
      c *= 0.85 + 0.15*sin(vUv.y*uRes.y*0.8);                // scanlines
      gl_FragColor = out3(c);
    }`,

    frutiger: HEAD + `void main(){             // Frutiger Aero: aqua-green nature glass + rising bubbles + gloss
      vec3 c = src();
      c = sat(c, 1.24); c.b *= 1.05; c.r *= 0.96;            // candy chroma, cool cast
      float L = luma(c);
      vec3 gm = grad4(L,
        vec3(0.02,0.14,0.20), vec3(0.16,0.66,0.58),
        vec3(0.45,0.85,0.96), vec3(1.00,0.99,0.94), 0.42, 0.75);
      c = mix(c, gm, 0.34);
      c += glow(vUv, 0.60, 3.2) * 0.6;                       // glossy gel bloom
      float aspect = uRes.x/uRes.y;
      for(int i=0;i<7;i++){                                  // rising bubbles
        float fi = float(i);
        float bx = fract(hash(vec2(fi,2.0)) + sin(uTime*0.15+fi)*0.02);
        float by = fract(hash(vec2(fi,5.0)) - uTime*(0.03+0.02*hash(vec2(fi,9.0))));
        vec2 d = (vUv - vec2(bx,by)); d.x *= aspect;
        float r = 0.018 + 0.03*hash(vec2(fi,7.0));
        float e = length(d)/r;
        float rim = smoothstep(1.0,0.75,e) * smoothstep(0.55,1.0,e);  // fresnel rim
        float spec = smoothstep(0.35,0.0,length(d-vec2(-r*0.3,-r*0.3))/r);
        c += rim*vec3(0.35,0.75,0.85)*0.5 + spec*0.5;
      }
      gl_FragColor = out3(c);
    }`,

    painting: HEAD + `
      // one Kuwahara quadrant (4x4 in a corner direction): mean + scalar variance
      void quad(vec2 sgn, out vec3 mo, out float vo){
        vec2 px = 1.0/uRes; vec3 m=vec3(0.0), m2=vec3(0.0);
        for(int i=0;i<=3;i++){ for(int j=0;j<=3;j++){
          vec3 t = texture2D(uTex, vUv + vec2(float(i),float(j))*sgn*px).rgb;
          m += t; m2 += t*t;
        }}
        m/=16.0; m2/=16.0; mo=m; vo=dot(m2-m*m, vec3(1.0));
      }
      void main(){                              // Painting: Kuwahara oil cells + canvas tooth + watercolour wash
        vec3 m0,m1,m2,m3; float v0,v1,v2,v3;
        quad(vec2(-1.,-1.),m0,v0); quad(vec2(1.,-1.),m1,v1);
        quad(vec2(-1., 1.),m2,v2); quad(vec2(1., 1.),m3,v3);
        vec3 paint = m0; float best = v0;
        if(v1<best){best=v1; paint=m1;}
        if(v2<best){best=v2; paint=m2;}
        if(v3<best){best=v3; paint=m3;}
        paint = sat(paint, 1.2) * vec3(1.02,1.0,0.97);       // watercolour vibrance + warm wash
        paint += (hash(floor(vUv*uRes/3.0))-0.5)*0.05;       // canvas tooth
        gl_FragColor = out3(paint);
      }`,

    comic: HEAD + `void main(){                // Comic Book: bold posterised fills + Ben-Day halftone
      vec3 c = sat(src(), 1.5);
      c = floor(c*8.0 + 0.5)/8.0;                            // 8 flat bands
      float L = luma(c);
      float a = radians(70.0); mat2 R = mat2(cos(a),-sin(a),sin(a),cos(a));
      vec2 g = R * (vUv*uRes);
      float dots = sin(g.x*0.7)*sin(g.y*0.7);                // Ben-Day screen
      float ink = step(dots, (0.5-L)*1.6);                  // dots concentrate in darks
      c *= mix(1.0, 0.7, ink * smoothstep(0.6,0.2,L));
      gl_FragColor = out3(c);
    }`,

    print: HEAD + `void main(){                // Print Art: woodblock flat fields + key-block lines + washi
      vec3 c = sat(src(), 1.3);
      c = floor(c*5.0 + 0.5)/5.0;                            // heavy flatten (cel bands)
      vec3 indigo = vec3(0.12,0.18,0.34);
      c = mix(c, c*vec3(0.9,0.95,1.1)+indigo*0.12, 0.35);    // Ukiyo-e indigo/earth lean
      float key = smoothstep(0.18,0.5, sobel(vUv));          // key-block ink edges
      c *= 1.0 - key*0.9;
      c *= 0.97 + (hash(floor(vUv*uRes/2.0))-0.5)*0.06;      // washi paper
      gl_FragColor = out3(c);
    }`,

    pencil: HEAD + `void main(){               // Pencil Sketch: graphite contours + cross-hatch on warm paper
      float L = luma(src());
      float edge = smoothstep(0.10,0.45, sobel(vUv));
      vec3 paper = vec3(0.95,0.93,0.87);
      vec3 lead  = vec3(0.22,0.21,0.23);
      float h1 = smoothstep(0.45,0.55, fract((vUv.x+vUv.y)*uRes.y*0.05));
      float h2 = smoothstep(0.45,0.55, fract((vUv.x-vUv.y)*uRes.y*0.05));
      float hatch = (1.0-smoothstep(0.3,0.7,L)) * (1.0-h1)*0.5 + (1.0-smoothstep(0.0,0.4,L))*(1.0-h2)*0.5;
      float ink = clamp(edge + hatch, 0.0, 1.0);
      gl_FragColor = out3(mix(paper, lead, ink));
    }`,

    studio: HEAD + `void main(){               // Studio: deeper blacks, gentle contrast, vibrance, clarity
      vec2 px = 1.0/uRes; vec3 o = texture2D(uTex,vUv).rgb;
      vec3 c = max(o-0.012, 0.0)/0.988;
      c = (c-0.5)*1.10 + 0.5;
      c = sat(c, 1.12);
      vec3 blur = (texture2D(uTex,vUv+vec2(px.x,0)).rgb+texture2D(uTex,vUv-vec2(px.x,0)).rgb
                  +texture2D(uTex,vUv+vec2(0,px.y)).rgb+texture2D(uTex,vUv-vec2(0,px.y)).rgb)*0.25;
      c += (o - blur) * 0.18;                                 // midtone clarity
      gl_FragColor = out3(c);
    }`,

    reading: HEAD + `void main(){              // Reading: warm paper-white, lifted dark UI, re-crisped text
      vec3 c = src();
      c.r *= 1.04; c.b *= 0.96;                              // warm white
      c = mix(c, vec3(luma(c)), 0.06); c *= vec3(1.03,1.01,0.95); // subtle sepia bind
      c += 0.05*(1.0-smoothstep(0.0,0.3,luma(c)));           // lift glare-y dark UI
      c = (c-0.5)*0.94 + 0.5;                                // pull peak white down
      vec2 px = 1.0/uRes;
      vec3 blur = (texture2D(uTex,vUv+vec2(px.x,0)).rgb+texture2D(uTex,vUv-vec2(px.x,0)).rgb
                  +texture2D(uTex,vUv+vec2(0,px.y)).rgb+texture2D(uTex,vUv-vec2(0,px.y)).rgb)*0.25;
      c += (texture2D(uTex,vUv).rgb - blur)*0.45;            // unsharp text
      gl_FragColor = out3(c);
    }`,

    night: HEAD + `void main(){                // Night Light: strong amber, dimmed, de-glared
      vec3 c = src();
      c.r *= 1.12; c.b *= 0.76; c.g *= 0.99;                 // warm, blue-reduced
      c -= 0.05;                                             // dim
      c = (c-0.5)*0.95 + 0.5;
      gl_FragColor = out3(max(c,0.0));
    }`,

    crisp: HEAD + `void main(){                // Crisp Text: pure unsharp acuity, no colour change
      vec2 px = 1.0/uRes;
      vec3 c = texture2D(uTex,vUv).rgb;
      vec3 blur = (texture2D(uTex,vUv+vec2(px.x,0)).rgb+texture2D(uTex,vUv-vec2(px.x,0)).rgb
                  +texture2D(uTex,vUv+vec2(0,px.y)).rgb+texture2D(uTex,vUv-vec2(0,px.y)).rgb)*0.25;
      c += (c - blur)*0.85;
      gl_FragColor = out3(c);
    }`,
  };

  // Composite: prism-dispersion sweep between two pre-rendered worlds.
  const COMPOSITE = `
    precision highp float;
    varying vec2 vUv;
    uniform sampler2D uFrom, uTo;
    uniform vec2  uRes;
    uniform float uProg;   // 0..1
    vec3 spectrum(float t){ return clamp(vec3(
      0.5+0.5*cos(6.2831*(t+0.00)), 0.5+0.5*cos(6.2831*(t+0.33)), 0.5+0.5*cos(6.2831*(t+0.66))), 0.0, 1.0); }
    vec3 split(sampler2D s, vec2 uv, float d){
      return vec3(texture2D(s, uv+vec2(d,0.0)).r, texture2D(s, uv).g, texture2D(s, uv-vec2(d,0.0)).b);
    }
    void main(){
      float edge = uProg*1.25 - 0.12;          // spectral seam sweeps left -> right
      float dd = vUv.x - edge;
      float band = exp(-pow(dd*13.0, 2.0));     // bright dispersion band at the seam
      float disp = band*0.03 + sin(uProg*3.14159)*0.004;
      vec3 from = split(uTo,   vUv, disp);      // ahead of the seam: the new world
      vec3 to   = split(uFrom, vUv, disp);      // behind the seam: the old world
      float reveal = smoothstep(0.02, -0.02, dd);
      vec3 c = mix(to, from, reveal);
      c += band * spectrum(vUv.y*0.6 + uProg) * 1.2;  // the prism beam
      gl_FragColor = vec4(c, 1.0);
    }`;

  // --- WebGL plumbing ------------------------------------------------------
  function sh(gl, type, s){ const o=gl.createShader(type); gl.shaderSource(o,s); gl.compileShader(o);
    if(!gl.getShaderParameter(o,gl.COMPILE_STATUS)){ console.error(gl.getShaderInfoLog(o), s); return null; } return o; }
  function prog(gl, fs){ const p=gl.createProgram();
    gl.attachShader(p, sh(gl,gl.VERTEX_SHADER,VERT)); gl.attachShader(p, sh(gl,gl.FRAGMENT_SHADER,fs));
    gl.linkProgram(p); if(!gl.getProgramParameter(p,gl.LINK_STATUS)){ console.error(gl.getProgramInfoLog(p)); return null; } return p; }
  function makeTex(gl){ const t=gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D,t);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR); return t; }
  function makeFBO(gl, w, h){ const t=makeTex(gl);
    gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,w,h,0,gl.RGBA,gl.UNSIGNED_BYTE,null);
    const f=gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER,f);
    gl.framebufferTexture2D(gl.FRAMEBUFFER,gl.COLOR_ATTACHMENT0,gl.TEXTURE_2D,t,0);
    gl.bindFramebuffer(gl.FRAMEBUFFER,null); return { tex:t, fbo:f, w, h }; }

  // --- Mock macOS desktop (drawn to a 2D canvas; the renderer's input) ------
  function makeScene(){
    const c = document.createElement('canvas'); c.width = 1440; c.height = 900;
    const x = c.getContext('2d');
    const rr = (X,Y,W,H,r)=>{ x.beginPath(); x.moveTo(X+r,Y); x.arcTo(X+W,Y,X+W,Y+H,r); x.arcTo(X+W,Y+H,X,Y+H,r); x.arcTo(X,Y+H,X,Y,r); x.arcTo(X,Y,X+W,Y,r); x.closePath(); };
    function draw(t){
      const W=c.width, H=c.height;
      const g = x.createLinearGradient(0,0,W,H); const a=Math.sin(t*0.25)*0.5+0.5;
      g.addColorStop(0,`hsl(${258+a*26},78%,20%)`); g.addColorStop(0.5,`hsl(${298+a*36},72%,27%)`); g.addColorStop(1,`hsl(${188+a*26},82%,25%)`);
      x.fillStyle=g; x.fillRect(0,0,W,H);
      for(let i=0;i<6;i++){ const bx=W*(0.12+0.16*i)+Math.sin(t*0.4+i)*44, by=H*(0.28+0.12*(i%3))+Math.cos(t*0.34+i)*34;
        const rg=x.createRadialGradient(bx,by,0,bx,by,300); rg.addColorStop(0,['#ff3df0','#8b5cff','#2fd9ff','#b6ff3d','#ffd23d','#ff7a3d'][i]+'4d'); rg.addColorStop(1,'#0000'); x.fillStyle=rg; x.fillRect(0,0,W,H); }
      // menu bar
      x.fillStyle='rgba(10,8,20,0.5)'; x.fillRect(0,0,W,36);
      x.fillStyle='#fff'; x.font='600 16px Inter, system-ui, sans-serif';
      x.fillText('  Spectra   File   Edit   Effects   Window', 18, 24);
      x.textAlign='right'; x.fillText('100%   Sat 9:41', W-18, 24); x.textAlign='left';
      // photos-ish window with colourful tiles (gives every world tonal range to chew on)
      rr(120,150,520,440,18); x.fillStyle='rgba(18,14,34,0.86)'; x.fill();
      rr(120,150,520,46,18); x.fillStyle='rgba(34,26,60,0.92)'; x.fill();
      ['#ff5f57','#febc2e','#28c840'].forEach((col,i)=>{ x.beginPath(); x.arc(150+i*24,173,7,0,7); x.fillStyle=col; x.fill(); });
      const swatches=['#ff6b9d','#ffd23d','#3dd6ff','#b6ff3d','#c77dff','#ff8a3d','#36e0a8','#7d8cff','#ff5470','#5fe0c0','#ffc14d','#9d6bff'];
      for(let i=0;i<12;i++){ const px=150+(i%4)*120, py=224+Math.floor(i/4)*116;
        rr(px,py,100,96,12); x.fillStyle=swatches[i]; x.fill();
        x.fillStyle='rgba(255,255,255,0.18)'; rr(px,py,100,34,12); x.fill(); }
      // control window mirroring the app's preset list
      rr(700,300,440,380,16); x.fillStyle='rgba(14,10,28,0.94)'; x.fill();
      x.fillStyle='#b6ff3d'; x.font='600 15px "Space Grotesk", ui-monospace, monospace'; x.fillText('● shading  ·  16 worlds', 728,338);
      x.fillStyle='#cfcae8'; x.font='500 15px Inter, sans-serif';
      ['Painting','Comic Book','Cyberpunk','Fuji-Film','The Matrix','Frutiger Aero','CRT Display','VHS Tape'].forEach((s,i)=>{ x.fillStyle=i===2?'#ff3df0':'#cfcae8'; x.fillText('◆  '+s, 728, 376+i*34); });
      // dock
      const dw=560, dx=(W-dw)/2, dy=H-96;
      rr(dx,dy,dw,76,22); x.fillStyle='rgba(245,244,255,0.16)'; x.fill();
      ['#ff3df0','#8b5cff','#2fd9ff','#b6ff3d','#ffd23d','#ff8a3d','#3dffd2','#ff5470'].forEach((col,i)=>{ rr(dx+22+i*66,dy+12,52,52,13); x.fillStyle=col; x.fill(); });
    }
    return { canvas:c, draw };
  }

  // --- Boot ----------------------------------------------------------------
  function init(){
    const canvas = document.getElementById('stage');
    if(!canvas) return;
    const gl = canvas.getContext('webgl', { antialias:false, premultipliedAlpha:false, powerPreference:'high-performance' });
    if(!gl){ document.body.classList.add('no-gl'); return; }

    const programs = {}; for(const k in WORLDS) programs[k]=prog(gl, WORLDS[k]);
    const composite = prog(gl, COMPOSITE);

    const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);

    const sceneTex = makeTex(gl);
    let fboA=null, fboB=null;
    const scene = makeScene();

    const state = { cur:'painting', from:null, prog:1, tStart:0, dur:0.95, amount:0.9, start:performance.now(), lastScene:-1 };

    function resize(){
      const dpr = Math.min(window.devicePixelRatio||1, 1.4);
      canvas.width = Math.round(innerWidth*dpr); canvas.height = Math.round(innerHeight*dpr);
      fboA = makeFBO(gl, canvas.width, canvas.height); fboB = makeFBO(gl, canvas.width, canvas.height);
    }
    addEventListener('resize', resize); resize();

    function drawQuad(p){ const loc=gl.getAttribLocation(p,'aPos'); gl.bindBuffer(gl.ARRAY_BUFFER,buf);
      gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc,2,gl.FLOAT,false,0,0); gl.drawArrays(gl.TRIANGLES,0,3); }

    function renderWorld(id, target){
      const p = programs[id] || programs.painting;
      gl.bindFramebuffer(gl.FRAMEBUFFER, target?target.fbo:null);
      gl.viewport(0,0,canvas.width,canvas.height);
      gl.useProgram(p);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, sceneTex);
      gl.uniform1i(gl.getUniformLocation(p,'uTex'),0);
      gl.uniform2f(gl.getUniformLocation(p,'uRes'), canvas.width, canvas.height);
      gl.uniform1f(gl.getUniformLocation(p,'uTime'), state.time);
      gl.uniform1f(gl.getUniformLocation(p,'uAmount'), state.amount);
      drawQuad(p);
    }

    function frame(now){
      state.time = (now - state.start)/1000;
      // refresh the mock desktop ~20fps (cheap; shaders animate on uTime anyway)
      if(state.time - state.lastScene > 0.05){ scene.draw(state.time); state.lastScene = state.time;
        gl.bindTexture(gl.TEXTURE_2D, sceneTex); gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
        try{ gl.texImage2D(gl.TEXTURE_2D,0,gl.RGB,gl.RGB,gl.UNSIGNED_BYTE, scene.canvas); }catch(e){} }

      if(state.from && state.prog < 1){
        state.prog = Math.min(1, (state.time - state.tStart)/state.dur);
        renderWorld(state.from, fboA);
        renderWorld(state.cur,  fboB);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0,0,canvas.width,canvas.height);
        gl.useProgram(composite);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, fboA.tex); gl.uniform1i(gl.getUniformLocation(composite,'uFrom'),0);
        gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, fboB.tex); gl.uniform1i(gl.getUniformLocation(composite,'uTo'),1);
        gl.uniform2f(gl.getUniformLocation(composite,'uRes'), canvas.width, canvas.height);
        gl.uniform1f(gl.getUniformLocation(composite,'uProg'), state.prog);
        drawQuad(composite);
        if(state.prog >= 1) state.from = null;
      } else {
        renderWorld(state.cur, null);
      }
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);

    window.Spectra = {
      worlds: Object.keys(WORLDS),
      current: () => state.cur,
      transitionTo(id){ if(!programs[id] || id===state.cur || state.prog<1) return false;
        state.from = state.cur; state.cur = id; state.prog = 0; state.tStart = state.time; return true; },
      setAmount(a){ state.amount = Math.max(0, Math.min(1, a)); },
      busy: () => state.prog < 1,
    };
    document.dispatchEvent(new Event('spectra-ready'));
  }

  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
