#include "../lib/render.slang"
#include "../lib/color.slang"

[Param(0.02, -0.3, 0.3)] uniform float threshold;
[Param(0.65, 0.0, 1.0)]  uniform float saturation;

static const uint NONE = 0xFFFFFFFFu;

struct Region { Atomic<uint> peak; }

RWStructuredBuffer<Atomic<uint>> labels;
RWStructuredBuffer<Region> regions;

uint labelAt(int2 p) { return labels[p.y * int(engine.size.x) + p.x].load(); }

[shader("compute")]
[numthreads(8, 8, 1)]
void seed(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    labels[i].store(heightAt(int2(tid.xy)) > threshold ? i : NONE);
}

[shader("compute")]
[numthreads(8, 8, 1)]
[Iterations(16)]
void merge(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint self = labels[i].load();
    if (self == NONE) return;

    uint best = self;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 q = int2(tid.xy) + int2(dx, dy);
            if (any(q < int2(0)) || any(q >= int2(engine.size))) continue;
            uint l = labelAt(q);
            if (l != NONE) best = min(best, l);
        }
    }

    // Pulling our own root down as well as ourselves is what lets a merge reach
    // the whole region instead of crawling one cell per iteration.
    if (best < self) {
        labels[self].min(best);
        labels[i].min(best);
    }

    uint root = labels[i].load();
    labels[i].min(labels[root].load());
}

[shader("compute")]
[numthreads(8, 8, 1)]
void clearRegions(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    regions[cellIndex(tid.xy)].peak.store(0);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void measure(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint root = labels[i].load();
    if (root == NONE) return;

    // Height in the high bits so an atomic max finds the region's summit.
    uint packed = (uint(saturate(heightAt(int2(tid.xy)) * 2.0 + 0.5) * 65535.0) << 16) | (i & 0xFFFFu);
    regions[root].peak.max(packed);
}

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    int2 p = cellOf(v.uv);
    float shade = shading(v.uv);

    uint root = labelAt(p);
    if (root == NONE) return float4(float3(0.13, 0.14, 0.17) * shade * 1.6, 1.0);

    uint peak = regions[root].peak.load() & 0xFFFFu;
    float2 summit = float2(peak % engine.size.x, peak / engine.size.x) / float2(engine.size);
    return float4(placeColor(summit, saturation) * shade, 1.0);
}
