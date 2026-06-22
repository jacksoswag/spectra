// Spectra cinematic — stick-figure rig.
// A figure is a skeleton of local joint coords (pelvis at origin, +y is down on the
// canvas, so "up" is negative). A POSE is the 10 joint coords. A character is a list of
// keyframes { t (0..1 within its shot), world, pose }; sample() interpolates them.
// Exposes window.Rig = { POSES, character, drawFigure, lerpPose }.

(() => {
  'use strict';

  // Joint keys: head, chest, eL/hL (elbow/hand left), eR/hR, kL/fL (knee/foot left), kR/fR.
  // pelvis is always [0,0]. Figure ~76px tall at scale 1 (head y=-46, feet y=+30).
  const P = (head, chest, eL, hL, eR, hR, kL, fL, kR, fR) => ({ head, chest, eL, hL, eR, hR, kL, fL, kR, fR });

  const POSES = {
    idle:    P([0,-46],[0,-30],[-9,-22],[-13,-9],[9,-22],[13,-9],[-6,12],[-7,30],[6,12],[7,30]),
    walkA:   P([0,-46],[0,-30],[-10,-20],[-14,-6],[8,-22],[12,-12],[-2,12],[-6,30],[8,12],[12,28]),
    walkB:   P([0,-46],[0,-30],[8,-22],[12,-12],[-10,-20],[-14,-6],[8,12],[12,28],[-2,12],[-6,30]),
    runA:    P([3,-46],[1,-30],[6,-22],[12,-14],[-8,-20],[-13,-8],[10,10],[16,24],[-8,12],[-12,30]),
    runB:    P([3,-46],[1,-30],[-8,-20],[-13,-8],[6,-22],[12,-14],[-8,12],[-12,30],[10,10],[16,24]),
    reach:   P([2,-47],[0,-30],[-9,-22],[-13,-9],[10,-30],[16,-45],[-6,12],[-7,30],[6,12],[7,30]),
    grab:    P([1,-46],[0,-30],[10,-25],[18,-23],[12,-26],[20,-24],[-6,12],[-8,28],[6,12],[8,28]),
    punch:   P([4,-44],[2,-30],[-6,-20],[-10,-10],[14,-26],[26,-24],[-8,12],[-12,30],[8,10],[14,24]),
    recoil:  P([-6,-44],[-3,-28],[-12,-30],[-16,-40],[12,-30],[16,-40],[-10,12],[-16,28],[2,12],[6,30]),
    jump:    P([0,-48],[0,-32],[-12,-34],[-16,-44],[12,-34],[16,-44],[-7,2],[-10,12],[7,2],[10,12]),
    crouch:  P([0,-36],[0,-24],[-10,-18],[-14,-10],[10,-18],[14,-10],[-9,4],[-10,18],[9,4],[10,18]),
    paint:   P([2,-46],[1,-30],[6,-22],[12,-18],[14,-28],[24,-30],[-6,12],[-8,28],[7,12],[10,28]),
    dodge:   P([-10,-42],[-5,-28],[-16,-26],[-22,-20],[6,-24],[10,-30],[-11,10],[-18,26],[5,12],[9,30]),
    amazed:  P([0,-48],[0,-30],[-11,-28],[-15,-36],[11,-28],[15,-36],[-6,12],[-7,30],[6,12],[7,30]),
    present: P([2,-46],[1,-30],[-8,-22],[-12,-12],[14,-28],[24,-26],[-6,12],[-7,30],[7,12],[10,28]),
    detective: P([6,-40],[2,-26],[-8,-20],[-12,-12],[12,-22],[22,-15],[-8,6],[-10,20],[8,6],[10,20]),
    down:    P([-24,-6],[-10,-2],[-16,-12],[-22,-16],[-2,-8],[4,-14],[8,-2],[20,-4],[8,4],[20,6]),
    frozen:  P([3,-45],[1,-29],[-7,-21],[-11,-11],[13,-27],[24,-25],[-8,11],[-12,29],[8,11],[14,25]),
  };

  const lerp = (a, b, t) => a + (b - a) * t;
  const lerpPt = (a, b, t) => [lerp(a[0], b[0], t), lerp(a[1], b[1], t)];
  const smooth = (t) => t * t * (3 - 2 * t);

  function lerpPose(a, b, t) {
    const o = {};
    for (const k in a) o[k] = lerpPt(a[k], b[k], t);
    return o;
  }
  const resolve = (p) => (typeof p === 'string' ? POSES[p] || POSES.idle : p);

  const defWorld = (w) => ({ x: 0, y: 0, s: 1, rot: 0, flip: 1, ...w });

  // A character drives off a keyframe list. sample(localT 0..1) -> { world, pose, action }.
  // `pose` is the interpolated skeleton (canvas backend); `action` is the discrete pose
  // name of the active keyframe (Rive backend maps it to a state-machine state).
  function character(keys) {
    const ks = keys.map(k => ({ t: k.t, world: defWorld(k.world), pose: resolve(k.pose), name: typeof k.pose === 'string' ? k.pose : 'idle' }));
    return {
      keys: ks,
      sample(localT) {
        if (localT <= ks[0].t) return { world: ks[0].world, pose: ks[0].pose, action: ks[0].name };
        const last = ks[ks.length - 1];
        if (localT >= last.t) return { world: last.world, pose: last.pose, action: last.name };
        let i = 0; while (i < ks.length - 1 && ks[i + 1].t < localT) i++;
        const a = ks[i], b = ks[i + 1];
        const raw = (localT - a.t) / (b.t - a.t);
        const e = (b.ease === 'linear') ? raw : smooth(raw);
        const world = {
          x: lerp(a.world.x, b.world.x, e), y: lerp(a.world.y, b.world.y, e),
          s: lerp(a.world.s, b.world.s, e), rot: lerp(a.world.rot, b.world.rot, e),
          flip: e < 0.5 ? a.world.flip : b.world.flip,
        };
        return { world, pose: lerpPose(a.pose, b.pose, e), action: a.name };
      },
    };
  }

  // Draw a figure onto a 2D context. A dark contour pass underneath keeps the figure
  // readable over any shaded background; the coloured pass rides on top.
  function drawFigure(ctx, world, pose, color, opts = {}) {
    const w = defWorld(world);
    const s = w.s, f = w.flip;
    const X = (p) => w.x + f * p[0] * s;
    const Y = (p) => w.y + p[1] * s;
    const headR = (opts.headR || 7) * s;
    const pelvis = [0, 0];
    ctx.save();
    if (w.rot) { ctx.translate(w.x, w.y); ctx.rotate(w.rot); ctx.translate(-w.x, -w.y); }
    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    const skeleton = () => {
      const seg = (...pts) => { ctx.beginPath(); ctx.moveTo(X(pts[0]), Y(pts[0])); for (let i = 1; i < pts.length; i++) ctx.lineTo(X(pts[i]), Y(pts[i])); ctx.stroke(); };
      seg(pelvis, pose.chest); seg(pose.chest, pose.eL, pose.hL); seg(pose.chest, pose.eR, pose.hR);
      seg(pelvis, pose.kL, pose.fL); seg(pelvis, pose.kR, pose.fR); seg(pose.chest, pose.head);
    };
    const base = (opts.weight || 4.0) * s;
    // dark contour underlay
    ctx.shadowBlur = 0; ctx.strokeStyle = 'rgba(6,5,12,0.9)'; ctx.lineWidth = base + 3.5; skeleton();
    ctx.fillStyle = 'rgba(6,5,12,0.9)'; ctx.beginPath(); ctx.arc(X(pose.head), Y(pose.head), headR + 1.8, 0, 7); ctx.fill();
    // coloured top
    if (opts.glow) { ctx.shadowColor = color; ctx.shadowBlur = 12 * s; }
    ctx.strokeStyle = color; ctx.lineWidth = base; skeleton();
    ctx.fillStyle = color; ctx.beginPath(); ctx.arc(X(pose.head), Y(pose.head), headR, 0, 7); ctx.fill();
    ctx.restore();
    return { x: w.x, y: w.y, s, f, X, Y, pose };  // handle back for props (magnifier, etc.)
  }

  window.Rig = { POSES, character, drawFigure, lerpPose };
})();
