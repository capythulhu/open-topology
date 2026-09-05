#include "../lib/render.slang"
#include "../lib/components.slang"
#include "../lib/color.slang"
#include "../lib/labels.slang"

// Finds every raised object and measures it: peak height, footprint, and
// volume, in millimetres, cm², and mL, lettered beside each one. The finding
// is components.slang; this file is the accounting.

[Param(80.0, 4.0, 3000.0)]  uniform float minCells;

// Heights are summed as integers in these units so the atomics can do it.
static const float QUANTA = 4096.0;

struct Region {
    Atomic<uint> count;
    Atomic<uint> sum;
    Atomic<uint> peak;
    Atomic<uint> sumX;
    Atomic<uint> sumY;
}

RWStructuredBuffer<Region> regions;
RWStructuredBuffer<Atomic<uint>> taken;
[Labels] RWStructuredBuffer<Label> labels;

[shader("compute")]
[numthreads(8, 8, 1)]
void reset(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    regions[i].count.store(0);
    regions[i].sum.store(0);
    regions[i].peak.store(0);
    regions[i].sumX.store(0);
    regions[i].sumY.store(0);
    if (i < MAX_LABELS) labels[i].shown = 0;
    if (i == 0) taken[0].store(0);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void tally(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint root = owner[i].load();
    if (root == NONE) return;

    uint q = uint(max(heightAt(int2(tid.xy)), 0.0) * QUANTA);
    regions[root].count.add(1u);
    regions[root].sum.add(q);
    regions[root].peak.max(q);
    regions[root].sumX.add(tid.x);
    regions[root].sumY.add(tid.y);
}

// One thread per region — the root cell — claims three label slots and fills
// them, so however many objects there are, only the first MAX_LABELS / 3 letter.
[shader("compute")]
[numthreads(8, 8, 1)]
void annotate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    if (owner[i].load() != i) return;

    uint count = regions[i].count.load();
    if (float(count) < minCells) return;

    uint slot = taken[0].add(1u) * 3;
    if (slot + 2 >= MAX_LABELS) return;

    float cellArea = engine.cellMm * engine.cellMm;
    float peak = float(regions[i].peak.load()) / QUANTA;

    Label label;
    label.cell = float2(regions[i].sumX.load(), regions[i].sumY.load()) / float(count);
    label.height = peak;
    label.shown = 1;
    label.tag = TAG_NONE;

    label.unit = UNIT_MM;
    label.value = peak * engine.heightMm;
    label.line = 0;
    labels[slot] = label;

    label.unit = UNIT_CM2;
    label.value = float(count) * cellArea / 100.0;
    label.line = 1;
    labels[slot + 1] = label;

    label.unit = UNIT_ML;
    label.value = float(regions[i].sum.load()) / QUANTA * engine.heightMm * cellArea / 1000.0;
    label.line = 2;
    labels[slot + 2] = label;
}

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    int2 p = cellOf(v.uv);
    float shade = shading(v.uv);

    // Whatever is not an object is background, and stays out of the way.
    uint root = ownerAt(p);
    if (root == NONE) return float4(float3(0.11, 0.12, 0.15) * (0.6 + 0.4 * shade), 1.0);

    // Each object tinted by where it sits, so neighbours read as different things.
    uint count = max(regions[root].count.load(), 1u);
    float2 centre = float2(regions[root].sumX.load(), regions[root].sumY.load()) / float(count);
    float3 tint = placeColor(centre / float2(engine.size), 0.55);
    float lift = saturate(heightSmooth(v.uv) / 0.5);
    return float4(lerp(tint * 0.7, tint + 0.25, lift) * shade, 1.0);
}
