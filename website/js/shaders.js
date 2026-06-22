// Spectra shaders — the 16 real preset worlds (faithful to BuiltInPresets.swift),
// shared by the cinematic engine. GLSL ES 1.00. One source of truth.
// Exposes window.SPECTRA_SHADERS = { HEAD, WORLDS, COMPOSITE, SIGNATURE }.

(() => {
  'use strict';

  const HEAD = `
    precision highp float;
    varying vec2 vUv;
    uniform sampler2D uTex;
    uniform vec2  uRes;
    uniform float uTime;
    uniform float uAmount;
    const float PI = 3.14159265;
    float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
    float luma(vec3 c){ return dot(c, vec3(0.299, 0.587, 0.114)); }
    vec3  sat(vec3 c, float s){ return clamp(mix(vec3(luma(c)), c, s), 0.0, 1.0); }
    vec3  src(){ return texture2D(uTex, vUv).rgb; }
    vec3 glow(vec2 uv, float thr, float stride){
      vec2 px = stride / uRes; vec3 s = vec3(0.0); float w = 0.0;
      for(int i=-2;i<=2;i++){ for(int j=-2;j<=2;j++){
        vec2 o = vec2(float(i), float(j)); float k = exp(-dot(o,o)/4.0);
        s += max(texture2D(uTex, uv + o*px).rgb - thr, 0.0) * k; w += k;
      }}
      return s / w;
    }
    float sobel(vec2 uv){
      vec2 px = 1.0 / uRes;
      float l00=luma(texture2D(uTex,uv+px*vec2(-1.,-1.)).rgb), l01=luma(texture2D(uTex,uv+px*vec2(0.,-1.)).rgb), l02=luma(texture2D(uTex,uv+px*vec2(1.,-1.)).rgb);
      float l10=luma(texture2D(uTex,uv+px*vec2(-1.,0.)).rgb),                                                     l12=luma(texture2D(uTex,uv+px*vec2(1.,0.)).rgb);
      float l20=luma(texture2D(uTex,uv+px*vec2(-1.,1.)).rgb), l21=luma(texture2D(uTex,uv+px*vec2(0.,1.)).rgb),  l22=luma(texture2D(uTex,uv+px*vec2(1.,1.)).rgb);
      float gx=(l02+2.0*l12+l22)-(l00+2.0*l10+l20); float gy=(l20+2.0*l21+l22)-(l00+2.0*l01+l02);
      return length(vec2(gx,gy));
    }
    vec3 grad4(float t, vec3 a, vec3 b, vec3 c, vec3 d, float pb, float pc){
      if(t < pb) return mix(a, b, t/pb);
      if(t < pc) return mix(b, c, (t-pb)/(pc-pb));
      return mix(c, d, (t-pc)/(1.0-pc));
    }
    vec4 out3(vec3 fx){ return vec4(clamp(mix(src(), fx, uAmount), 0.0, 1.0), 1.0); }
  `;

  const WORLDS = {
    none: HEAD + `void main(){ gl_FragColor = vec4(src(), 1.0); }`,

    golden: HEAD + `void main(){
      vec3 c = src();
      c += glow(vUv, 0.6, 2.6) * 0.6;
      c += glow(vUv, 0.6, 5.0) * vec3(0.20,0.10,0.04);
      c.r *= 1.06; c.b *= 0.93; c += vec3(0.02,0.01,-0.01);
      float leak = smoothstep(0.75,1.5,vUv.x+vUv.y) * (0.55+0.45*sin(uTime*0.25));
      c += leak * vec3(0.16,0.07,0.02);
      gl_FragColor = out3(c);
    }`,

    fuji: HEAD + `void main(){
      vec3 c = src();
      c.r *= 1.06; c.b *= 0.92;
      c = (c-0.5)*1.14 + 0.5 + 0.015;
      c.g += 0.025 * (1.0 - abs(luma(c)-0.5)*2.0);
      c = sat(c, 1.20);
      c += glow(vUv, 0.70, 3.0) * vec3(0.10,0.06,0.02);
      vec3 gr = vec3(hash(vUv*uRes+uTime), hash(vUv*uRes+uTime+7.0), hash(vUv*uRes+uTime+13.0)) - 0.5;
      c += gr * 0.13;
      float dust = step(0.9965, hash(floor(vUv*vec2(240.0,150.0))+floor(uTime*7.0)));
      c *= 1.0 - dust*0.55;
      gl_FragColor = out3(c);
    }`,

    noir: HEAD + `void main(){
      vec3 s = src();
      float g = dot(s, vec3(0.30,0.62,0.08));
      g = (g-0.5)*1.39 + 0.5 - 0.02;
      vec3 c = vec3(g);
      c += (1.0-g)*vec3(-0.03,0.0,0.05);
      c += g*vec3(0.02,0.01,-0.04);
      c += glow(vUv, 0.62, 3.2) * vec3(0.26,0.15,0.10);
      c += (hash(vUv*uRes)-0.5)*0.10;
      gl_FragColor = out3(c);
    }`,

    cyberpunk: HEAD + `void main(){
      vec3 c = src();
      c = max(c-0.06, 0.0)/0.94;
      c = (c-0.5)*1.32 + 0.5;
      c = sat(c, 1.45);
      float L = luma(c);
      vec3 gm = grad4(L, vec3(0.02,0.05,0.09), vec3(0.28,0.10,0.30), vec3(0.85,0.18,0.55), vec3(0.55,0.92,1.00), 0.45, 0.78);
      c = mix(c, gm, 0.55);
      c += glow(vUv, 0.55, 3.4) * 0.75;
      gl_FragColor = out3(c);
    }`,

    crt: HEAD + `void main(){
      vec2 uv = vUv; vec2 cc = uv-0.5;
      uv += cc * dot(cc,cc) * 0.12;
      if(uv.x<0.0||uv.x>1.0||uv.y<0.0||uv.y>1.0){ gl_FragColor = out3(vec3(0.02)); return; }
      vec3 c = texture2D(uTex, uv).rgb;
      c += glow(uv, 0.45, 2.2) * 0.5;
      c *= 0.78 + 0.22*sin(uv.y*uRes.y*1.1);
      float m = mod(gl_FragCoord.x, 3.0);
      c *= (m<1.0)?vec3(1.08,0.9,0.9):(m<2.0)?vec3(0.9,1.08,0.9):vec3(0.9,0.9,1.08);
      c *= smoothstep(1.25, 0.35, length(cc));
      c += 0.03;
      gl_FragColor = out3(c);
    }`,

    vhs: HEAD + `void main(){
      vec2 uv = vUv;
      float trk = sin((uv.y + uTime*0.2)*8.0);
      uv.x += (hash(vec2(floor(uv.y*90.0), floor(uTime*8.0)))-0.5)*0.012 + step(0.93,trk)*0.01;
      vec3 c;
      c.r = texture2D(uTex, uv + vec2(0.010,0.0)).r;
      c.g = texture2D(uTex, uv).g;
      c.b = texture2D(uTex, uv - vec2(0.006,0.0)).b;
      c.r += texture2D(uTex, uv + vec2(0.018,0.0)).r * 0.25;
      c.r = min(c.r, 1.0);
      c.r *= 1.07; c.b *= 0.95;
      c = sat(c, 1.18);
      c += (hash(uv*uRes + uTime)-0.5)*0.10;
      c *= 0.9 + 0.1*sin(uv.y*uRes.y*0.6);
      gl_FragColor = out3(c);
    }`,

    matrix: HEAD + `void main(){
      vec3 s = src(); float L = luma(s);
      vec3 c = vec3(0.0, L, L*0.35);
      c = (c-0.5)*1.3 + 0.5; c.g = max(c.g-0.06, 0.0);
      c = sat(c, 0.5);
      float cols = 64.0; float col = floor(vUv.x*cols);
      float spd = 0.5 + hash(vec2(col,1.0))*1.3;
      float head = fract(vUv.y*1.0 - uTime*spd*0.18 + hash(vec2(col,3.0)));
      float bright = smoothstep(0.0,0.05,head) * smoothstep(0.6,0.0,head);
      float glyph = step(0.45, hash(floor(vec2(vUv.x*cols, vUv.y*44.0 + floor(uTime*spd*9.0)))));
      c += bright*glyph*vec3(0.25,1.0,0.45);
      c *= 0.85 + 0.15*sin(vUv.y*uRes.y*0.8);
      gl_FragColor = out3(c);
    }`,

    frutiger: HEAD + `void main(){
      vec3 c = src();
      c = sat(c, 1.24); c.b *= 1.05; c.r *= 0.96;
      float L = luma(c);
      vec3 gm = grad4(L, vec3(0.02,0.14,0.20), vec3(0.16,0.66,0.58), vec3(0.45,0.85,0.96), vec3(1.00,0.99,0.94), 0.42, 0.75);
      c = mix(c, gm, 0.34);
      c += glow(vUv, 0.60, 3.2) * 0.6;
      float aspect = uRes.x/uRes.y;
      for(int i=0;i<7;i++){
        float fi = float(i);
        float bx = fract(hash(vec2(fi,2.0)) + sin(uTime*0.15+fi)*0.02);
        float by = fract(hash(vec2(fi,5.0)) - uTime*(0.03+0.02*hash(vec2(fi,9.0))));
        vec2 d = (vUv - vec2(bx,by)); d.x *= aspect;
        float r = 0.018 + 0.03*hash(vec2(fi,7.0));
        float e = length(d)/r;
        float rim = smoothstep(1.0,0.75,e) * smoothstep(0.55,1.0,e);
        float spec = smoothstep(0.35,0.0,length(d-vec2(-r*0.3,-r*0.3))/r);
        c += rim*vec3(0.35,0.75,0.85)*0.5 + spec*0.5;
      }
      gl_FragColor = out3(c);
    }`,

    painting: HEAD + `
      void quad(vec2 sgn, out vec3 mo, out float vo){
        vec2 px = 1.0/uRes; vec3 m=vec3(0.0), m2=vec3(0.0);
        for(int i=0;i<=3;i++){ for(int j=0;j<=3;j++){
          vec3 t = texture2D(uTex, vUv + vec2(float(i),float(j))*sgn*px).rgb;
          m += t; m2 += t*t;
        }}
        m/=16.0; m2/=16.0; mo=m; vo=dot(m2-m*m, vec3(1.0));
      }
      void main(){
        vec3 m0,m1,m2,m3; float v0,v1,v2,v3;
        quad(vec2(-1.,-1.),m0,v0); quad(vec2(1.,-1.),m1,v1);
        quad(vec2(-1., 1.),m2,v2); quad(vec2(1., 1.),m3,v3);
        vec3 paint = m0; float best = v0;
        if(v1<best){best=v1; paint=m1;}
        if(v2<best){best=v2; paint=m2;}
        if(v3<best){best=v3; paint=m3;}
        paint = sat(paint, 1.2) * vec3(1.02,1.0,0.97);
        paint += (hash(floor(vUv*uRes/3.0))-0.5)*0.05;
        gl_FragColor = out3(paint);
      }`,

    comic: HEAD + `void main(){
      vec3 c = sat(src(), 1.5);
      c = floor(c*8.0 + 0.5)/8.0;
      float L = luma(c);
      float a = radians(70.0); mat2 R = mat2(cos(a),-sin(a),sin(a),cos(a));
      vec2 g = R * (vUv*uRes);
      float dots = sin(g.x*0.7)*sin(g.y*0.7);
      float ink = step(dots, (0.5-L)*1.6);
      c *= mix(1.0, 0.7, ink * smoothstep(0.6,0.2,L));
      gl_FragColor = out3(c);
    }`,

    print: HEAD + `void main(){
      vec3 c = sat(src(), 1.3);
      c = floor(c*5.0 + 0.5)/5.0;
      vec3 indigo = vec3(0.12,0.18,0.34);
      c = mix(c, c*vec3(0.9,0.95,1.1)+indigo*0.12, 0.35);
      float key = smoothstep(0.18,0.5, sobel(vUv));
      c *= 1.0 - key*0.9;
      c *= 0.97 + (hash(floor(vUv*uRes/2.0))-0.5)*0.06;
      gl_FragColor = out3(c);
    }`,

    pencil: HEAD + `void main(){
      float L = luma(src());
      float edge = smoothstep(0.10,0.45, sobel(vUv));
      vec3 paper = vec3(0.95,0.93,0.87); vec3 lead = vec3(0.22,0.21,0.23);
      float h1 = smoothstep(0.45,0.55, fract((vUv.x+vUv.y)*uRes.y*0.05));
      float h2 = smoothstep(0.45,0.55, fract((vUv.x-vUv.y)*uRes.y*0.05));
      float hatch = (1.0-smoothstep(0.3,0.7,L)) * (1.0-h1)*0.5 + (1.0-smoothstep(0.0,0.4,L))*(1.0-h2)*0.5;
      float ink = clamp(edge + hatch, 0.0, 1.0);
      gl_FragColor = out3(mix(paper, lead, ink));
    }`,

    studio: HEAD + `void main(){
      vec2 px = 1.0/uRes; vec3 o = texture2D(uTex,vUv).rgb;
      vec3 c = max(o-0.012, 0.0)/0.988;
      c = (c-0.5)*1.10 + 0.5;
      c = sat(c, 1.12);
      vec3 blur = (texture2D(uTex,vUv+vec2(px.x,0)).rgb+texture2D(uTex,vUv-vec2(px.x,0)).rgb
                  +texture2D(uTex,vUv+vec2(0,px.y)).rgb+texture2D(uTex,vUv-vec2(0,px.y)).rgb)*0.25;
      c += (o - blur) * 0.18;
      gl_FragColor = out3(c);
    }`,

    reading: HEAD + `void main(){
      vec3 c = src();
      c.r *= 1.04; c.b *= 0.96;
      c = mix(c, vec3(luma(c)), 0.06); c *= vec3(1.03,1.01,0.95);
      c += 0.05*(1.0-smoothstep(0.0,0.3,luma(c)));
      c = (c-0.5)*0.94 + 0.5;
      vec2 px = 1.0/uRes;
      vec3 blur = (texture2D(uTex,vUv+vec2(px.x,0)).rgb+texture2D(uTex,vUv-vec2(px.x,0)).rgb
                  +texture2D(uTex,vUv+vec2(0,px.y)).rgb+texture2D(uTex,vUv-vec2(0,px.y)).rgb)*0.25;
      c += (texture2D(uTex,vUv).rgb - blur)*0.45;
      gl_FragColor = out3(c);
    }`,

    night: HEAD + `void main(){
      vec3 c = src();
      c.r *= 1.12; c.b *= 0.76; c.g *= 0.99;
      c -= 0.05;
      c = (c-0.5)*0.95 + 0.5;
      gl_FragColor = out3(max(c,0.0));
    }`,

    crisp: HEAD + `void main(){
      vec2 px = 1.0/uRes; vec3 c = texture2D(uTex,vUv).rgb;
      vec3 blur = (texture2D(uTex,vUv+vec2(px.x,0)).rgb+texture2D(uTex,vUv-vec2(px.x,0)).rgb
                  +texture2D(uTex,vUv+vec2(0,px.y)).rgb+texture2D(uTex,vUv-vec2(0,px.y)).rgb)*0.25;
      c += (c - blur)*0.85;
      gl_FragColor = out3(c);
    }`,
  };

  // Preset switch: a colored shock-wavefront expanding from the orb (uOrigin),
  // revealing the new world inside the ring. The orb "fires its beam" outward.
  const COMPOSITE = `
    precision highp float;
    varying vec2 vUv;
    uniform sampler2D uFrom, uTo;
    uniform vec2  uRes;
    uniform float uProg;
    uniform vec2  uOrigin;
    uniform vec3  uColor;
    void main(){
      vec2 d = vUv - uOrigin; d.x *= uRes.x/uRes.y;
      float dist = length(d);
      float radius = uProg * 1.7;
      float reveal = smoothstep(radius+0.05, radius-0.05, dist);
      vec3 c = mix(texture2D(uFrom,vUv).rgb, texture2D(uTo,vUv).rgb, reveal);
      float ring = exp(-pow((dist-radius)*14.0, 2.0));
      c += ring * uColor * 1.5 * (1.0 - uProg*0.35);
      gl_FragColor = vec4(c, 1.0);
    }`;

  // Each world's signature colour, used for its switch beam + UI accents.
  const SIGNATURE = {
    none:[0.55,0.5,0.8], golden:[1.0,0.72,0.28], fuji:[1.0,0.66,0.4], noir:[0.85,0.85,0.9],
    cyberpunk:[1.0,0.24,0.94], crt:[0.5,0.9,1.0], vhs:[1.0,0.4,0.55], matrix:[0.18,1.0,0.4],
    frutiger:[0.4,0.9,0.85], painting:[1.0,0.6,0.5], comic:[1.0,0.85,0.24], print:[0.3,0.45,0.85],
    pencil:[0.8,0.78,0.72], studio:[0.7,0.78,1.0], reading:[1.0,0.85,0.6], night:[1.0,0.7,0.35], crisp:[0.8,0.85,1.0],
  };

  window.SPECTRA_SHADERS = { HEAD, WORLDS, COMPOSITE, SIGNATURE };
})();
