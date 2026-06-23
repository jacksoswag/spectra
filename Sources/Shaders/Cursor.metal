#include "SpectraCommon.h"

// Cursor compositing (MAOE §6). Draws a cursor sprite (texture 1, premultiplied alpha) onto
// the captured desktop (texture 0) within a UV-space rectangle, producing a combined image
// then fed through the full effect chain — so the cursor picks up the same look as everything
// else. `rect` is (minU, minV, maxU, maxV) in the target's top-left-origin UV space.
//
// `styleIndex` selects a restyle that operates on whatever sprite is bound (so it covers the
// system arrow / I-beam / resize states): 0 passthrough, 1 neon rim, 2 pixel-quantize, 3 tint.
// Sprite styles do no shader work (the sprite is substituted upstream in the sampler) and ride
// the passthrough branch. `intensity` cross-fades the restyle in; `tint` colours it.
//
// CPU mirror: `CursorUniforms` in CursorCompositor.swift (identical field order + padding).
struct CursorUniforms {
    float4 rect;       // minU, minV, maxU, maxV
    int   styleIndex;  // 0 passthrough, 1 neon, 2 pixel, 3 tint
    float intensity;   // 0..1 restyle strength
    float2 _pad;       // align the following float4 to 16 bytes
    float4 tint;       // restyle colour (rgb) + amount (a)
};

fragment float4 fx_cursor_composite(RasterizerData in [[stage_in]],
                                    texture2d<float> desktop [[texture(0)]],
                                    texture2d<float> cursor [[texture(1)]],
                                    constant CursorUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(desktop, in.uv).rgb;
    float2 r0 = u.rect.xy;
    float2 r1 = u.rect.zw;
    if (!(all(in.uv >= r0) && all(in.uv <= r1))) return float4(base, 1.0);

    float2 span = max(r1 - r0, float2(1.0e-5));
    float2 cuv = (in.uv - r0) / span;
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float k = clamp(u.intensity, 0.0, 1.0);

    // The sprite is rasterized top-row-first (a top-left-origin CGImage drawn into a
    // bottom-left-origin CGContext cancels out), matching the target's top-left UV origin.
    float4 c = cursor.sample(s, cuv);
    // Plain "over" composite of the unmodified sprite — the k==0 / passthrough result.
    float3 plain = base * (1.0 - c.a) + c.rgb;

    if (u.styleIndex == 1) {
        // Neon rim: a coloured halo hugging the sprite's outer edge, capped to a couple of
        // texels so the visual tip stays honest (clicks land on the real hotspot).
        float w = max(float(cursor.get_width()), 1.0);
        float h = max(float(cursor.get_height()), 1.0);
        float2 texel = float2(1.0 / w, 1.0 / h);
        float ring = 0.0;
        for (int oy = -2; oy <= 2; oy++) {
            for (int ox = -2; ox <= 2; ox++) {
                ring = max(ring, cursor.sample(s, cuv + float2(float(ox), float(oy)) * texel).a);
            }
        }
        float halo = clamp(ring - c.a, 0.0, 1.0);
        float3 glow = u.tint.rgb * halo * k;
        return float4(plain + glow, 1.0);
    } else if (u.styleIndex == 2) {
        // Pixel: quantize the sprite to chunky cells and tint it (Matrix green / Game Boy).
        float cells = 14.0;
        float2 q = (floor(cuv * cells) + 0.5) / cells;
        float4 pc = cursor.sample(s, q);
        float a = step(0.4, pc.a);
        float3 px = mix(pc.rgb, u.tint.rgb, u.tint.a);
        float3 styled = base * (1.0 - a) + px;
        return float4(mix(plain, styled, k), 1.0);
    } else if (u.styleIndex == 3) {
        // Tint: shift the sprite colour toward `tint` (warm night-light, etc.).
        float3 tinted = mix(c.rgb, c.rgb * u.tint.rgb, u.tint.a);
        float3 styled = base * (1.0 - c.a) + tinted;
        return float4(mix(plain, styled, k), 1.0);
    } else if (u.styleIndex == 4) {
        // Adaptive ink (Print Art): the dark woodblock pointer vanishes over a dark / similarly-
        // coloured desktop. Measure the local luma contrast between the sprite and the background
        // under it; where it's low, lift the sprite toward warm yellow/off-white (`tint.rgb`) so the
        // pointer always reads. High-contrast areas keep the original ink.
        const float3 W = float3(0.299, 0.587, 0.114);
        float3 sprite = c.rgb / max(c.a, 1.0e-3);                       // un-premultiply for an honest luma
        float contrast = abs(dot(sprite, W) - dot(base, W));
        float blend = (1.0 - smoothstep(0.08, 0.32, contrast)) * u.tint.a * k;
        float3 lifted = mix(c.rgb, u.tint.rgb * c.a, blend);           // stay premultiplied
        float3 styled = base * (1.0 - c.a) + lifted;
        return float4(styled, 1.0);
    }
    return float4(plain, 1.0);
}
