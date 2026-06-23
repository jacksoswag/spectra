// Pencil.metal — the Pencil-Sketch draw-on-screen tool (MAOE §7).
//
// `fx_pencil_stamp` is a tiny accumulation pass run by DisplayRenderer into a persistent r16Float
// layer while the LEFT button drags: it MAX-blends a soft capsule from the previous to the current
// cursor (so fast moves leave no gaps), with a width the renderer derives from the inverse pointer
// speed. A right-click clears the layer (a clear pass, not this shader). `fx_int_pencilDraw` then
// composites that stroke layer over the styled frame as graphite lines.

#include "SpectraCommon.h"

struct PencilStampUniforms {
    float2 prev;        // previous stamped point (UV)
    float2 cur;         // current cursor point (UV)
    float  halfWidth;   // stroke half-width (aspect-corrected UV)
    float  aspect;      // resolution.x / resolution.y
};

// Distance from p to the segment [a,b].
inline float pencil_distToSeg(float2 p, float2 a, float2 b) {
    float2 ab = b - a, ap = p - a;
    float t = clamp(dot(ap, ab) / max(dot(ab, ab), 1.0e-9), 0.0, 1.0);
    return length(ap - ab * t);
}

// Stamp pass: output the capsule coverage for this pixel. MAX-blended into the layer by the
// renderer, so this fullscreen pass only ever raises the existing stroke value, never erases it.
fragment float4 fx_pencil_stamp(RasterizerData in [[stage_in]],
                                constant PencilStampUniforms &u [[buffer(0)]]) {
    float2 p = in.uv;   p.x *= u.aspect;
    float2 a = u.prev;  a.x *= u.aspect;
    float2 b = u.cur;   b.x *= u.aspect;
    float d = pencil_distToSeg(p, a, b);
    float cov = smoothstep(u.halfWidth, u.halfWidth * 0.5, d);
    // Graphite tooth: nibble the coverage with fine static grain so the line reads hand-drawn.
    float tooth = 0.82 + 0.18 * spectra_hash21(floor(in.uv * 1100.0));
    return float4(cov * tooth, 0.0, 0.0, cov);
}

// Composite the persistent stroke layer over the styled frame as graphite lines.
// params: 0..3 ink colour, 4 strength
fragment float4 fx_int_pencilDraw(RasterizerData in [[stage_in]],
                                  texture2d<float> src [[texture(0)]], texture2d<float> orig [[texture(1)]],
                                  constant SpectraUniforms &u [[buffer(0)]],
                                  texture2d<float> drawLayer [[texture(14)]]) {
    float3 base = spectra_tex(src, in.uv).rgb;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float m = clamp(drawLayer.sample(s, in.uv).r, 0.0, 1.0);
    if (m <= 0.0) return float4(base, 1.0);
    float3 ink = float3(u.params[0], u.params[1], u.params[2]);
    float3 outc = mix(base, ink, m * max(u.params[4], 0.0));
    return spectra_compositeRGBA(base, outc, u);
}
