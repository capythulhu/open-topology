#include "../lib/render.slang"
#include "../lib/labels.slang"

// Fits a sphere to every object and says how well it fits. Anything resting on
// the floor is a spherical cap if it is a sphere at all, and a cap is fixed by
// its footprint and its peak: r = (R² + h²) / 2h. That needs only counts,
// sums, and a max — no normal equations, nothing that overflows an atomic.
// The surface is tinted by how far it sits from the fitted sphere.

[Param(0.03, 0.0, 0.3)]     uniform float cutoff;
[Param(80.0, 4.0, 3000.0)]  uniform float minCells;
[Param(6.0, 1.0, 20.0)]     uniform float tolerance;

static const uint NONE = 0xFFFFFFFFu;
static const float QUANTA = 4096.0;
static const float TENTHS = 10.0;

struct Region {
    Atomic<uint> count;
    Atomic<uint> sumX;
    Atomic<uint> sumY;
    Atomic<uint> peak;
    Atomic<uint> misfit;
}

RWStructuredBuffer<Atomic<uint>> owner;
RWStructuredBuffer<Region> regions;
RWStructuredBuffer<float> deviation;
RWStructuredBuffer<Atomic<uint>> taken;
[Labels] RWStructuredBuffer<Label> labels;

uint ownerAt(int2 p) { return owner[p.y * int(engine.size.x) + p.x].load(); }

struct Cap { float2 centre; float footprint; float height; float radius; };

Cap capOf(uint root) {
    uint count = max(regions[root].count.load(), 1u);
    Cap cap;
    cap.centre = float2(regions[root].sumX.load(), regions[root].sumY.load()) / float(count);
    cap.footprint = sqrt(float(count) / 3.14159265) * engine.cellMm;
    cap.height = float(regions[root].peak.load()) / QUANTA * engine.heightMm;
    cap.radius = (cap.footprint * cap.footprint + cap.height * cap.height) / max(2.0 * cap.height, 1e-3);
    return cap;
}

// Height the fitted sphere would have at this cell, in mm.
float predicted(Cap cap, int2 p) {
    float d = length((float2(p) - cap.centre) * engine.cellMm);
    if (d >= cap.footprint) return 0.0;
    float sunk = cap.radius - cap.height;
    return sqrt(max(cap.radius * cap.radius - d * d, 0.0)) - sunk;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void seed(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    owner[i].store(heightAt(int2(tid.xy)) > cutoff ? i : NONE);
    regions[i].count.store(0);
    regions[i].sumX.store(0);
    regions[i].sumY.store(0);
    regions[i].peak.store(0);
    regions[i].misfit.store(0);
    deviation[i] = 0.0;
    if (i < MAX_LABELS) labels[i].shown = 0;
    if (i == 0) taken[0].store(0);
}

[shader("compute")]
[numthreads(8, 8, 1)]
[Iterations(16)]
void merge(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint self = owner[i].load();
    if (self == NONE) return;

    uint best = self;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 q = int2(tid.xy) + int2(dx, dy);
            if (any(q < int2(0)) || any(q >= int2(engine.size))) continue;
            uint l = ownerAt(q);
            if (l != NONE) best = min(best, l);
        }
    }
    if (best < self) {
        owner[self].min(best);
        owner[i].min(best);
    }
    uint root = owner[i].load();
    owner[i].min(owner[root].load());
}

[shader("compute")]
[numthreads(8, 8, 1)]
void tally(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint root = owner[i].load();
    if (root == NONE) return;
    regions[root].count.add(1u);
    regions[root].sumX.add(tid.x);
    regions[root].sumY.add(tid.y);
    regions[root].peak.max(uint(max(heightAt(int2(tid.xy)), 0.0) * QUANTA));
}

// With the cap known, every cell measures its own distance from it, in tenths
// of a millimetre so the sum stays a plain integer.
[shader("compute")]
[numthreads(8, 8, 1)]
void compare(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint root = owner[i].load();
    if (root == NONE) return;

    Cap cap = capOf(root);
    float actual = heightAt(int2(tid.xy)) * engine.heightMm;
    float off = abs(actual - predicted(cap, int2(tid.xy)));
    deviation[i] = off;
    regions[root].misfit.add(uint(off * TENTHS));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void annotate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    if (owner[i].load() != i) return;
    uint count = regions[i].count.load();
    if (float(count) < minCells) return;

    uint slot = taken[0].add(1u) * 2;
    if (slot + 1 >= MAX_LABELS) return;

    Cap cap = capOf(i);
    float error = float(regions[i].misfit.load()) / TENTHS / float(count);

    Label label;
    label.cell = cap.centre;
    label.height = cap.height / engine.heightMm;
    label.shown = 1;
    label.reserved = 0;

    label.unit = UNIT_MM;
    label.value = cap.radius;
    label.line = 0;
    labels[slot] = label;

    label.unit = UNIT_PERCENT;
    label.value = 100.0 * error / max(cap.radius, 1.0);
    label.line = 1;
    labels[slot + 1] = label;
}

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    int2 p = cellOf(v.uv);
    float shade = shading(v.uv);

    uint root = ownerAt(p);
    if (root == NONE) return float4(float3(0.11, 0.12, 0.15) * (0.6 + 0.4 * shade), 1.0);

    // Teal where the surface lies on the fitted sphere, through amber to red as
    // it leaves it, so a dome reads as one colour and a hand as a patchwork.
    float off = saturate(deviation[cellIndex(uint2(p))] / tolerance);
    float3 fits = float3(0.20, 0.75, 0.70);
    float3 strays = float3(0.95, 0.35, 0.15);
    float3 tint = lerp(fits, strays, off);
    float lift = saturate(heightSmooth(v.uv) / 0.5);
    return float4(tint * (0.75 + 0.35 * lift) * shade, 1.0);
}
