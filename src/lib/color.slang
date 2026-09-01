#ifndef OT_COLOR
#define OT_COLOR

float3 hsv2rgb(float3 c) {
    float3 k = frac(c.x + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0;
    return c.z * lerp(float3(1.0), saturate(abs(k) - 1.0), c.y);
}

// Hue from a position rather than an id. Fed a region's summit, the color stays
// put as the region grows, and a region that splits keeps its color on the half
// that kept the peak.
float3 placeColor(float2 uv, float saturation) {
    return hsv2rgb(float3(frac(uv.x * 1.3 + uv.y * 2.1), saturation, 1.0));
}

static const float3 TERRAIN[6] = {
    float3(0.05, 0.16, 0.32),
    float3(0.16, 0.45, 0.60),
    float3(0.85, 0.79, 0.62),
    float3(0.40, 0.56, 0.30),
    float3(0.45, 0.40, 0.33),
    float3(0.93, 0.93, 0.91),
};

float3 terrain(float h) {
    float t = saturate(h + 0.5) * 5.0;
    uint i = uint(t);
    return lerp(TERRAIN[min(i, 4u)], TERRAIN[min(i + 1u, 5u)], frac(t));
}

#endif
