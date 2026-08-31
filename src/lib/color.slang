#ifndef OT_COLOR
#define OT_COLOR

float3 hsv2rgb(float3 c) {
    float3 k = frac(c.x + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0;
    return c.z * lerp(float3(1.0), saturate(abs(k) - 1.0), c.y);
}

float3 labelColor(uint id, float saturation) {
    return hsv2rgb(float3(frac(float(id) * 0.6180339887), saturation, 1.0));
}

#endif
