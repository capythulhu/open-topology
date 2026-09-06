#include "../lib/render.slang"
#include "../lib/components.slang"

[Param(80.0, 4.0, 3000.0)] uniform float minCells;
[Param(1.5, 1.1, 2.5)]     uniform float ringAt;

static const float QUANTA = 4096.0;
static const uint MAX_MARKS = 16;
static const float PI = 3.14159265;

struct Region {
    Atomic<uint> count;
    Atomic<uint> sum;
    Atomic<uint> sumX;
    Atomic<uint> sumY;
}

struct Mark {
    float2 center;
    float radius;
    float live;
}

RWStructuredBuffer<Region> regions;
RWStructuredBuffer<uint> rowRoots;
RWStructuredBuffer<Mark> marks;

[shader("compute")]
[numthreads(8, 8, 1)]
void reset(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    regions[i].count.store(0);
    regions[i].sum.store(0);
    regions[i].sumX.store(0);
    regions[i].sumY.store(0);
    if (i < MAX_MARKS) marks[i].live = 0.0;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void tally(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint root = owner[i].load();
    if (root == NONE) return;
    regions[root].count.add(1u);
    regions[root].sum.add(uint(max(heightAt(int2(tid.xy)), 0.0) * QUANTA));
    regions[root].sumX.add(tid.x);
    regions[root].sumY.add(tid.y);
}

bool qualifies(uint i) { return owner[i].load() == i && float(regions[i].count.load()) >= minCells; }

[shader("compute")]
[numthreads(8, 8, 1)]
void countRows(uint3 tid: SV_DispatchThreadID) {
    if (tid.x != 0 || tid.y >= engine.size.y) return;
    uint found = 0;
    for (uint x = 0; x < engine.size.x; x++) if (qualifies(cellIndex(uint2(x, tid.y)))) found++;
    rowRoots[tid.y] = found;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void place(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    if (!qualifies(i)) return;
    uint rank = 0;
    for (uint y = 0; y < tid.y; y++) rank += rowRoots[y];
    for (uint x = 0; x < tid.x; x++) if (qualifies(cellIndex(uint2(x, tid.y)))) rank++;
    if (rank >= MAX_MARKS) return;
    float count = float(regions[i].count.load());
    Mark m;
    m.center = float2(regions[i].sumX.load(), regions[i].sumY.load()) / count;
    m.radius = sqrt(count / PI);
    m.live = 1.0;
    marks[rank] = m;
}

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    float2 p = v.uv * float2(engine.size - 1);
    bool raised = ownerAt(cellOf(v.uv)) != NONE;
    float3 color = raised ? float3(0.15, 0.35, 1.0) : float3(0.45, 0.25, 0.05);
    for (uint k = 0; k < MAX_MARKS; k++) {
        Mark m = marks[k];
        if (m.live < 0.5) continue;
        float2 d = p - m.center;
        float dist = length(d);
        if (abs(dist - m.radius * ringAt) < 1.2) color = float3(1.0);
        if (dist < 2.5) color = float3(1.0, 0.1, 0.1);
        if (dist < m.radius * ringAt && dist > 4.0 && (abs(d.x) < 0.6 || abs(d.y) < 0.6)) color = float3(0.2, 0.9, 0.3);
    }
    return float4(color, 1.0);
}
