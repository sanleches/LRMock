//
//  RawLightKernels.metal
//  RawLight
//
//  GPU compute kernels for the Phase 2 imaging backend.
//
//  `rtContrast` is a faithful port of RawTherapee's contrast curve. The math
//  comes directly from rtengine/curves.h (GPLv3):
//      basel()/baseu()  — convex/concave base functions  (curves.h ~134-157)
//      cupper()/clower() — slope-controlled curves        (curves.h ~159-182)
//      p01()/p10()       — the smooth contrast S-curve     (curves.h ~453-460)
//  RawTherapee applies this per RGB channel; we do the same. Because this file
//  is derived from GPLv3 source, RawLight is distributed under GPLv3.
//
//  Porting notes:
//  * RT's `xlog`/`xexp` are fast approximations of log/exp; we use the hardware
//    log/exp here (identical result within float precision).
//  * `prot` is RawTherapee's highlight/shadow "protection" (recovery) parameter.
//

#include <metal_stdlib>
using namespace metal;

// Convex base function between (0,0) and (1,1); m1,m2 control end slopes.
// Port of CurveFactory::basel (curves.h).
static inline float rt_basel(float x, float m1, float m2) {
    if (x <= 0.0f) { return 0.0f; }
    float k  = sqrt((m1 - 1.0f) * (m1 - m2) * 0.5f) / (1.0f - m2);
    float l  = (m1 - m2) / (1.0f - m2) + k;
    float lx = log(x);
    return m2 * x + (1.0f - m2) * (2.0f - exp(k * lx)) * exp(l * lx);
}

// Concave base function; port of CurveFactory::baseu.
static inline float rt_baseu(float x, float m1, float m2) {
    return 1.0f - rt_basel(1.0f - x, m1, m2);
}

// Convex curve with slope m at (0,0); hr = highlight recovery.
// Port of CurveFactory::cupper.
static inline float rt_cupper(float x, float m, float hr) {
    if (hr > 1.0f) {
        return rt_baseu(x, m, 2.0f * (hr - 1.0f) / m);
    }
    float x1 = (1.0f - hr) / m;
    float x2 = x1 + hr;
    if (x >= x2) { return 1.0f; }
    if (x <  x1) { return x * m; }
    return 1.0f - hr + hr * rt_baseu((x - x1) / hr, m, 0.0f);
}

// Concave curve with slope m at (1,1); sr = shadow recovery.
// Port of CurveFactory::clower.
static inline float rt_clower(float x, float m, float sr) {
    return 1.0f - rt_cupper(1.0f - x, m, sr);
}

// Smooth contrast S-curve (shadows down, highlights up). Port of Curve::p01.
static inline float rt_p01(float x, float prot) {
    return x <= 0.5f
        ? rt_clower(x * 2.0f, 2.0f, prot) * 0.5f
        : 0.5f + rt_cupper((x - 0.5f) * 2.0f, 2.0f, prot) * 0.5f;
}

// Inverse S-curve used for de-contrast (contrast < 0). Port of Curve::p10.
static inline float rt_p10(float x, float prot) {
    return x <= 0.5f
        ? rt_cupper(x * 2.0f, 2.0f, prot) * 0.5f
        : 0.5f + rt_clower((x - 0.5f) * 2.0f, 2.0f, prot) * 0.5f;
}

// Applies the RT contrast curve to a single value.
// `amount` in [-1, 1]: >0 increases contrast, <0 flattens it.
static inline float rt_contrast_value(float x, float amount, float prot) {
    float c = clamp(x, 0.0f, 1.0f);
    float curved = amount >= 0.0f ? rt_p01(c, prot) : rt_p10(c, prot);
    float t = fabs(amount);
    return mix(c, curved, t);
}

kernel void rtContrast(texture2d<float, access::read>  inTex  [[texture(0)]],
                       texture2d<float, access::write> outTex [[texture(1)]],
                       constant float& amount [[buffer(0)]],
                       constant float& prot   [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float4 px = inTex.read(gid);
    float3 out = float3(
        rt_contrast_value(px.r, amount, prot),
        rt_contrast_value(px.g, amount, prot),
        rt_contrast_value(px.b, amount, prot)
    );
    outTex.write(float4(out, px.a), gid);
}
