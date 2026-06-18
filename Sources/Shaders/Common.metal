#include "SpectraCommon.h"

// Fullscreen triangle vertex shader. Produces a single oversized triangle that
// covers the viewport with no vertex buffer required.
vertex RasterizerData fullscreen_vertex(uint vid [[vertex_id]]) {
    RasterizerData out;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    out.uv = uv;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return out;
}

// Direct copy of the source texture. Used for the final present pass and as a
// no-op when the chain is empty.
fragment float4 passthrough_fragment(RasterizerData in [[stage_in]],
                                     texture2d<float> src [[texture(0)]]) {
    return spectra_tex(src, in.uv);
}

// Present with a vertical flip — used when source orientation is bottom-up.
fragment float4 passthrough_flip_fragment(RasterizerData in [[stage_in]],
                                          texture2d<float> src [[texture(0)]]) {
    return spectra_tex(src, float2(in.uv.x, 1.0 - in.uv.y));
}

// Final present with ordered dithering. The chain works in 16-bit float; writing
// that to an 8-bit drawable quantizes smooth gradients (especially blurs) into
// visible bands. A screen-space triangular-PDF dither of ~1 least-significant bit
// breaks the bands into imperceptible noise. Negligible on a 16-bit EDR drawable.
fragment float4 present_fragment(RasterizerData in [[stage_in]],
                                 texture2d<float> src [[texture(0)]]) {
    float3 c = spectra_tex(src, in.uv).rgb;
    float2 p = in.position.xy;
    float n1 = spectra_hash21(p);
    float n2 = spectra_hash21(p + 53.13);
    float3 dither = float3((n1 + n2 - 1.0) / 255.0);   // triangular PDF, ±1 LSB at 8-bit
    return float4(c + dither, 1.0);
}

// Final present when the chain rendered below native and is being upscaled to the
// drawable. Identical dither to `present_fragment`, but samples with a Catmull-Rom
// bicubic so a sub-native frame keeps near-native sharpness — smoothing the harsh
// step the eye sees between Native (1:1) and anything below it, and making the Auto
// governor's quality changes far less obvious. Used only on the upscale path (the
// renderer keeps the cheaper `present_fragment` for the 1:1 predither and 1:1 present).
fragment float4 present_upscale_fragment(RasterizerData in [[stage_in]],
                                         texture2d<float> src [[texture(0)]]) {
    float2 texSize = float2(src.get_width(), src.get_height());
    float3 c = spectra_bicubic(src, in.uv, texSize).rgb;
    float2 p = in.position.xy;
    float n1 = spectra_hash21(p);
    float n2 = spectra_hash21(p + 53.13);
    float3 dither = float3((n1 + n2 - 1.0) / 255.0);
    return float4(c + dither, 1.0);
}
