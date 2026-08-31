#include "../lib/field.slang"

RWStructuredBuffer<float> heights;

[Param(4.0, 0.5, 16.0)]  uniform float frequency;
[Param(0.35, 0.0, 1.0)]  uniform float amplitude;
[Param(0.06, 0.0, 1.0)]  uniform float speed;
[Param(4.0, 1.0, 6.0)]   uniform float octaves;

float hash(float2 p) { return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + float2(1, 0));
    float c = hash(i + float2(0, 1));
    float d = hash(i + float2(1, 1));
    return lerp(lerp(a, b, w.x), lerp(c, d, w.x), w.y);
}

float fbm(float2 p, int octaveCount) {
    float sum = 0.0;
    float weight = 0.5;
    for (int i = 0; i < octaveCount; i++) {
        sum += valueNoise(p) * weight;
        p *= 2.0;
        weight *= 0.5;
    }
    return sum;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void generate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    float2 uv = float2(tid.xy) / float2(engine.size);
    float t = engine.time * speed;
    float h = fbm(uv * frequency + float2(t, t * 0.6), int(octaves));
    heights[cellIndex(tid.xy)] = (h - 0.5) * amplitude;
}
