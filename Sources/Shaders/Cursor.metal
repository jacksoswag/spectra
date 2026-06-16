#include "SpectraCommon.h"

// Cursor compositing. Draws a cursor sprite (texture 1, premultiplied alpha) onto
// the captured desktop (texture 0) within a UV-space rectangle, producing a
// combined image that is then fed through the full effect chain — so the cursor
// picks up the same look as everything else. `rect` is (minU, minV, maxU, maxV)
// in the target's top-left-origin UV space.
struct CursorUniforms {
    float4 rect;
};

fragment float4 fx_cursor_composite(RasterizerData in [[stage_in]],
                                    texture2d<float> desktop [[texture(0)]],
                                    texture2d<float> cursor [[texture(1)]],
                                    constant CursorUniforms &u [[buffer(0)]]) {
    float3 base = spectra_tex(desktop, in.uv).rgb;
    float2 r0 = u.rect.xy;
    float2 r1 = u.rect.zw;
    if (all(in.uv >= r0) && all(in.uv <= r1)) {
        float2 span = max(r1 - r0, float2(1.0e-5));
        float2 cuv = (in.uv - r0) / span;
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        // The sprite is rasterized top-row-first (drawing a top-left-origin CGImage
        // into the bottom-left-origin CGContext cancels out), matching the target's
        // top-left UV origin — so sample V directly. Flipping it draws the cursor
        // upside down.
        float4 c = cursor.sample(s, float2(cuv.x, cuv.y));
        return float4(base * (1.0 - c.a) + c.rgb, 1.0);   // premultiplied "over"
    }
    return float4(base, 1.0);
}
