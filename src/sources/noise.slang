#include "../lib/field.slang"

RWStructuredBuffer<float> heights;

[Param(4.0, 0.5, 16.0)]  uniform float frequency;
[Param(0.35, 0.0, 1.0)]  uniform float amplitude;
[Param(0.06, 0.0, 1.0)]  uniform float speed;
[Param(4.0, 1.0, 6.0)]   uniform float octaves;

float hash(float3 p) { return frac(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453); }

// Time is the third axis, so the terrain swells and sinks in place instead of
// sliding across the field. A sandbox never translates, and anything keyed to a
// feature's position (cluster colours) would drift if it did.
float valueNoise(float3 p) {
    float3 i = floor(p);
    float3 f = p - i;
    float3 w = f * f * (3.0 - 2.0 * f);

    float near = lerp(lerp(hash(i + float3(0, 0, 0)), hash(i + float3(1, 0, 0)), w.x),
                      lerp(hash(i + float3(0, 1, 0)), hash(i + float3(1, 1, 0)), w.x), w.y);
    float far = lerp(lerp(hash(i + float3(0, 0, 1)), hash(i + float3(1, 0, 1)), w.x),
                     lerp(hash(i + float3(0, 1, 1)), hash(i + float3(1, 1, 1)), w.x), w.y);
    return lerp(near, far, w.z);
}

float fbm(float3 p, int octaveCount) {
    float sum = 0.0;
    float weight = 0.5;
    float total = 0.0;
    for (int i = 0; i < octaveCount; i++) {
        sum += valueNoise(p) * weight;
        total += weight;
        p *= 2.0;
        weight *= 0.5;
    }
    return sum / total;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void generate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    float2 uv = float2(tid.xy) / float2(engine.size);
    float h = fbm(float3(uv * frequency, engine.time * speed), int(octaves));
    heights[cellIndex(tid.xy)] = (h - 0.5) * amplitude;
}
