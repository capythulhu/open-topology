#include "../lib/field.slang"

// A flat floor with a few domes on it and one low ridge — the sandbox with
// styrofoam hemispheres and a hand, roughly. They drift a little so the effects
// have something to react to.

RWStructuredBuffer<float> heights;
RWStructuredBuffer<float> rawHeights;

[Param(0.32, 0.05, 0.5)]    uniform float height;
[Param(0.06, 0.0, 0.4)]     uniform float speed;
[Param(200.0, 20.0, 600.0)] uniform float relief;

float dome(float2 p, float2 centre, float radius) {
    float d = length(p - centre) / radius;
    return d < 1.0 ? sqrt(1.0 - d * d) : 0.0;
}

float ridge(float2 p, float2 from, float2 to, float radius) {
    float2 along = to - from;
    float t = saturate(dot(p - from, along) / dot(along, along));
    float d = length(p - (from + along * t)) / radius;
    return d < 1.0 ? sqrt(1.0 - d * d) : 0.0;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void generate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;

    // Square units whatever the field's aspect, so a dome stays round.
    float2 p = float2(tid.xy) / float(max(engine.size.x, engine.size.y));
    float t = engine.time * speed;

    float h = dome(p, float2(0.30 + 0.04 * sin(t), 0.36), 0.12);
    h = max(h, 0.8 * dome(p, float2(0.63, 0.28 + 0.04 * cos(t * 1.3)), 0.085));
    h = max(h, 0.55 * dome(p, float2(0.70, 0.68), 0.15));
    h = max(h, 0.45 * ridge(p, float2(0.18, 0.72), float2(0.44, 0.62 + 0.03 * sin(t * 0.7)), 0.05));

    uint i = cellIndex(tid.xy);
    heights[i] = h * height;
    rawHeights[i] = heights[i];
}
