#include "../lib/render.slang"
#include "../lib/color.slang"

[Param(0.02, -0.3, 0.3)] uniform float threshold;
[Param(0.65, 0.0, 1.0)]  uniform float saturation;

static const uint NONE = 0xFFFFFFFFu;

RWStructuredBuffer<uint> labels;

[shader("compute")]
[numthreads(8, 8, 1)]
void seed(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    labels[i] = heightAt(int2(tid.xy)) > threshold ? i : NONE;
}

// Racy on purpose: labels only ever decrease, so parallel writes still converge.
[shader("compute")]
[numthreads(8, 8, 1)]
[Iterations(32)]
void propagate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint m = labels[i];
    if (m == NONE) return;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 q = int2(tid.xy) + int2(dx, dy);
            if (any(q < int2(0)) || any(q >= int2(engine.size))) continue;
            uint l = labels[q.y * int(engine.size.x) + q.x];
            if (l != NONE) m = min(m, l);
        }
    }

    // Jump straight to the candidate's own label so chains collapse in log steps
    // instead of one cell per iteration.
    labels[i] = min(m, labels[m]);
}

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    int2 p = cellOf(v.uv);
    uint l = labels[cellIndex(uint2(p))];
    float shade = 0.35 + 0.65 * saturate(dot(normalAt(p), normalize(float3(0.35, 1.0, 0.25))));

    if (l == NONE) return float4(float3(0.13, 0.14, 0.17) * shade * 1.6, 1.0);
    return float4(labelColor(l, saturation) * shade, 1.0);
}
