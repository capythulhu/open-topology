#include "../lib/render.slang"
#include "../lib/color.slang"

[Param(20.0, 2.0, 200.0)] uniform float interval;
[Param(1.5, 0.5, 6.0)]   uniform float width;

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    float h = heightSmooth(v.uv);
    float line = contourMask(h, interval / engine.heightMm, width);
    float3 color = lerp(terrain(h), float3(0.04), line);
    return float4(color * shading(v.uv), 1.0);
}
