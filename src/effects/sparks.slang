#include "../lib/surface.slang"

[Param(0.03, 0.0, 0.3)]  uniform float cutoff;
[Param(0.8, 0.1, 3.0)]   uniform float size;
[Param(0.4, 0.0, 1.0)]   uniform float rise;

struct Dot {
    float4 clip : SV_Position;
    float2 corner : CORNER;
    float lift : LIFT;
};

static const float2 CORNERS[6] = {
    float2(-1, -1), float2(1, -1), float2(-1, 1),
    float2(1, -1), float2(1, 1), float2(-1, 1),
};

[shader("vertex")]
[PerCell(6)]
Dot vertexMain(uint vid: SV_VertexID) {
    uint cell = vid / 6;
    uint2 p = uint2(cell % engine.size.x, cell / engine.size.x);
    float h = rawHeightAt(int2(p));

    Dot o;
    o.corner = CORNERS[vid % 6];
    o.lift = saturate((h - cutoff) / max(0.5 - cutoff, 0.01));
    if (h < cutoff) {
        o.clip = CULLED;
        return o;
    }

    float4 clip = project(cellWorld(p, h + o.lift * rise * 0.2));
    clip.xy += o.corner * cellOnScreen() * size * 0.5;
    o.clip = clip;
    return o;
}

[shader("fragment")]
float4 fragmentMain(Dot d) : SV_Target {
    float r = length(d.corner);
    if (r > 1.0) discard;

    float3 ember = float3(0.95, 0.30, 0.08);
    float3 flame = float3(1.0, 0.92, 0.55);
    float glow = 1.0 - r * r;
    return float4(lerp(ember, flame, d.lift) * glow, 1.0);
}
