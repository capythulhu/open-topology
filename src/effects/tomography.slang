#include "../lib/render.slang"

[Param(0.4, 0.0, 1.0)]   uniform float sweep;
[Param(0.12, 0.0, 0.5)]  uniform float level;
[Param(0.45, 0.05, 0.5)] uniform float top;

float scanHeight() {
    if (sweep <= 0.0) return level;
    float phase = frac(engine.time * sweep * 0.25);
    return top * (1.0 - abs(phase * 2.0 - 1.0));
}
#define COMPONENT_THRESHOLD scanHeight()

#include "../lib/components.slang"
#include "../lib/labels.slang"

static const float BAND = 0.012;

struct Slice {
    Atomic<uint> count;
    Atomic<uint> sumX;
    Atomic<uint> sumY;
}

RWStructuredBuffer<Slice> slices;
RWStructuredBuffer<Atomic<uint>> taken;
[Labels] RWStructuredBuffer<Label> labels;

[shader("compute")]
[numthreads(8, 8, 1)]
void reset(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    slices[i].count.store(0);
    slices[i].sumX.store(0);
    slices[i].sumY.store(0);
    if (i < MAX_LABELS) labels[i].shown = 0;
    if (i == 0) taken[0].store(1);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void tally(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint root = owner[cellIndex(tid.xy)].load();
    if (root == NONE) return;
    slices[root].count.add(1u);
    slices[root].sumX.add(tid.x);
    slices[root].sumY.add(tid.y);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void annotate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    float scan = scanHeight();

    if (i == 0) {
        Label plane;
        plane.cell = float2(0.0, float(engine.size.y - 1));
        plane.height = scan;
        plane.value = scan * engine.heightMm;
        plane.unit = UNIT_MM;
        plane.tag = TAG_NONE;
        plane.line = 0;
        plane.shown = 1;
        labels[0] = plane;
    }

    if (owner[i].load() != i) return;
    uint count = slices[i].count.load();
    if (count < 24u) return;

    uint slot = taken[0].add(1u);
    if (slot >= MAX_LABELS) return;

    Label label;
    label.cell = float2(slices[i].sumX.load(), slices[i].sumY.load()) / float(count);
    label.height = scan;
    label.value = float(count) * engine.cellMm * engine.cellMm / 100.0;
    label.unit = UNIT_CM2;
    label.tag = TAG_NONE;
    label.line = 0;
    label.shown = 1;
    labels[slot] = label;
}

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    float h = heightSmooth(v.uv);
    float scan = scanHeight();
    float shade = shading(v.uv);

    if (abs(h - scan) < BAND) return float4(0.55, 1.0, 1.0, 1.0);

    if (h > scan) {
        float row = v.uv.y * float(engine.size.y - 1);
        if (uint(row) % 4u != 0u || frac(row) > 0.3) discard;
        return float4(float3(0.16, 0.30, 0.34) * shade, 1.0);
    }

    float toward = saturate(1.0 - (scan - h) / max(scan, 0.05));
    float3 deep = float3(0.05, 0.10, 0.16);
    float3 near = float3(0.14, 0.42, 0.50);
    return float4(lerp(deep, near, toward) * (0.5 + 0.5 * shade), 1.0);
}
