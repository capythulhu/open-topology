#include "../lib/surface.slang"
#include "../lib/components.slang"
#include "../lib/color.slang"
#include "../lib/labels.slang"

[Param(80.0, 4.0, 3000.0)] uniform float minCells;
[Param(6.0, 2.0, 24.0)]    uniform float wire;

static const float QUANTA = 4096.0;
static const float FINE = 16.0;
static const uint MAX_BOXES = 8;
static const uint MAX_LINKS = MAX_BOXES * (MAX_BOXES - 1) / 2;
static const uint EDGE_VERTICES = MAX_BOXES * 12 * 6;
static const uint LINK_VERTICES = MAX_LINKS * 6;

void pairOf(uint k, out uint first, out uint second) {
    uint pair = 0;
    first = 0;
    second = 0;
    for (uint a = 0; a < MAX_BOXES; a++) {
        for (uint b = a + 1; b < MAX_BOXES; b++) {
            if (pair == k) {
                first = a;
                second = b;
            }
            pair++;
        }
    }
}

struct Region {
    Atomic<uint> count;
    Atomic<uint> sumX;
    Atomic<uint> sumY;
    Atomic<uint> peak;
    Atomic<int> xx;
    Atomic<int> yy;
    Atomic<int> xy;
    Atomic<int> minA;
    Atomic<int> maxA;
    Atomic<int> minB;
    Atomic<int> maxB;
    float axisX;
    float axisY;
}

struct Box {
    float2 centre;
    float2 axis;
    float2 half;
    float height;
    float shown;
}

RWStructuredBuffer<Region> regions;
RWStructuredBuffer<Box> boxes;
[Snapshot("boxes")] StructuredBuffer<Box> cages;
RWStructuredBuffer<Atomic<uint>> taken;
[Labels] RWStructuredBuffer<Label> labels;

float2 centreOf(uint root) {
    return float2(regions[root].sumX.load(), regions[root].sumY.load()) / float(max(regions[root].count.load(), 1u));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void reset(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    regions[i].count.store(0);
    regions[i].sumX.store(0);
    regions[i].sumY.store(0);
    regions[i].peak.store(0);
    regions[i].xx.store(0);
    regions[i].yy.store(0);
    regions[i].xy.store(0);
    regions[i].minA.store(0x7FFFFFFF);
    regions[i].maxA.store(-0x7FFFFFFF);
    regions[i].minB.store(0x7FFFFFFF);
    regions[i].maxB.store(-0x7FFFFFFF);
    if (i < MAX_BOXES) boxes[i].shown = 0.0;
    if (i < MAX_LABELS) labels[i].shown = 0;
    if (i == 0) taken[0].store(0);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void centroid(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint root = owner[cellIndex(tid.xy)].load();
    if (root == NONE) return;
    regions[root].count.add(1u);
    regions[root].sumX.add(tid.x);
    regions[root].sumY.add(tid.y);
    regions[root].peak.max(uint(max(heightAt(int2(tid.xy)), 0.0) * QUANTA));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void spread(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint root = owner[cellIndex(tid.xy)].load();
    if (root == NONE) return;
    float2 d = float2(tid.xy) - centreOf(root);
    regions[root].xx.add(int(d.x * d.x * 0.25));
    regions[root].yy.add(int(d.y * d.y * 0.25));
    regions[root].xy.add(int(d.x * d.y * 0.25));
}

[shader("compute")]
[numthreads(8, 8, 1)]
void orient(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    if (owner[i].load() != i) return;
    float xx = float(regions[i].xx.load());
    float yy = float(regions[i].yy.load());
    float xy = float(regions[i].xy.load());
    float theta = 0.5 * atan2(2.0 * xy, xx - yy);
    regions[i].axisX = cos(theta);
    regions[i].axisY = sin(theta);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void extents(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint root = owner[cellIndex(tid.xy)].load();
    if (root == NONE) return;
    float2 axis = float2(regions[root].axisX, regions[root].axisY);
    float2 d = float2(tid.xy) - centreOf(root);
    int a = int(dot(d, axis) * FINE);
    int b = int(dot(d, float2(-axis.y, axis.x)) * FINE);
    regions[root].minA.min(a);
    regions[root].maxA.max(a);
    regions[root].minB.min(b);
    regions[root].maxB.max(b);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void annotate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    if (owner[i].load() != i) return;
    if (float(regions[i].count.load()) < minCells) return;

    uint slot = taken[0].add(1u);
    if (slot >= MAX_BOXES) return;

    float2 axis = float2(regions[i].axisX, regions[i].axisY);
    float2 lo = float2(regions[i].minA.load(), regions[i].minB.load()) / FINE;
    float2 hi = float2(regions[i].maxA.load(), regions[i].maxB.load()) / FINE;
    float2 half = (hi - lo) * 0.5 + 0.5;
    float2 shift = (hi + lo) * 0.5;
    float peak = float(regions[i].peak.load()) / QUANTA;

    Box box;
    box.centre = centreOf(i) + axis * shift.x + float2(-axis.y, axis.x) * shift.y;
    box.axis = axis;
    box.half = half;
    box.height = peak;
    box.shown = 1.0;
    boxes[slot] = box;

    float angle = degrees(atan2(axis.y, axis.x));
    if (angle < 0.0) angle += 180.0;

    Label label;
    label.cell = box.centre;
    label.height = peak;
    label.shown = 1;

    label.tag = TAG_L; label.unit = UNIT_MM; label.value = half.x * 2.0 * engine.cellMm; label.line = 0;
    labels[slot * 3] = label;
    label.tag = TAG_W; label.value = half.y * 2.0 * engine.cellMm; label.line = 1;
    labels[slot * 3 + 1] = label;
    label.tag = TAG_NONE; label.unit = UNIT_DEG; label.value = angle; label.line = 2;
    labels[slot * 3 + 2] = label;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void link(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint k = cellIndex(tid.xy);
    if (k >= MAX_LINKS) return;

    uint first, second;
    pairOf(k, first, second);
    Box from = boxes[first];
    Box to = boxes[second];
    if (from.shown < 0.5 || to.shown < 0.5) return;

    float2 across = (to.centre - from.centre) * engine.cellMm;
    float up = (to.height - from.height) * engine.heightMm;

    Label label;
    label.cell = (from.centre + to.centre) * 0.5;
    label.height = (from.height + to.height) * 0.5;
    label.value = sqrt(dot(across, across) + up * up);
    label.unit = UNIT_MM;
    label.tag = TAG_NONE;
    label.line = 0;
    label.shown = 1;
    labels[MAX_BOXES * 3 + k] = label;
}

struct Wire {
    float4 clip : SV_Position;
    float2 uv : UV;
    float edge : EDGE;
};

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };
static const float2 CORNERS[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };

static const uint2 EDGES[12] = {
    uint2(0, 1), uint2(1, 3), uint2(3, 2), uint2(2, 0),
    uint2(4, 5), uint2(5, 7), uint2(7, 6), uint2(6, 4),
    uint2(0, 4), uint2(1, 5), uint2(2, 6), uint2(3, 7),
};

float3 cornerWorld(Box box, uint corner) {
    float along = (corner & 1u) != 0u ? box.half.x : -box.half.x;
    float across = (corner & 2u) != 0u ? box.half.y : -box.half.y;
    float h = (corner & 4u) != 0u ? box.height : 0.0;
    float2 cell = box.centre + box.axis * along + float2(-box.axis.y, box.axis.x) * across;
    return pointWorld(cell, h);
}

float4 ribbon(float3 a, float3 b, float2 corner, float width) {
    float4 from = project(a);
    float4 to = project(b);
    float2 dir = normalize((to.xy - from.xy) * float2(engine.aspect, 1.0) + 1e-6);
    float2 side = float2(-dir.y, dir.x) * width * float2(1.0 / engine.aspect, 1.0);
    float4 base = corner.x < 0.0 ? from : to;
    return float4(base.xy + side * corner.y, base.z - 0.002, 1.0);
}

[shader("vertex")]
[PerCell(6)]
[Vertices(744)]
Wire vertexMain(uint vid: SV_VertexID) {
    Wire o;
    o.uv = float2(0.0);
    o.edge = 0.0;

    uint cells = engine.size.x * engine.size.y;
    if (vid < cells * 6) {
        uint cell = vid / 6;
        uint2 origin = uint2(cell % engine.size.x, cell / engine.size.x);
        if (any(origin >= engine.size - 1)) {
            o.clip = CULLED;
            return o;
        }
        uint2 p = origin + QUAD[vid % 6];
        o.clip = project(cellWorld(p, heightAt(int2(p))));
        o.uv = float2(p) / float2(engine.size - 1);
        return o;
    }

    uint e = vid - cells * 6;
    float2 corner = CORNERS[e % 6];

    if (e < EDGE_VERTICES) {
        Box box = cages[e / 72];
        if (box.shown < 0.5) {
            o.clip = CULLED;
            return o;
        }
        uint2 ends = EDGES[(e / 6) % 12];
        o.clip = ribbon(cornerWorld(box, ends.x), cornerWorld(box, ends.y), corner, 0.0032);
        o.edge = 1.0;
        return o;
    }

    uint first, second;
    pairOf((e - EDGE_VERTICES) / 6, first, second);
    Box from = cages[first];
    Box to = cages[second];
    if (from.shown < 0.5 || to.shown < 0.5) {
        o.clip = CULLED;
        return o;
    }
    o.clip = ribbon(pointWorld(from.centre, from.height), pointWorld(to.centre, to.height), corner, 0.0016);
    o.edge = 2.0;
    return o;
}

[shader("fragment")]
float4 fragmentMain(Wire w) : SV_Target {
    if (w.edge > 1.5) return float4(1.0, 1.0, 1.0, 1.0);
    if (w.edge > 0.5) return float4(0.85, 0.97, 1.0, 1.0);

    int2 p = cellOf(w.uv);
    uint root = ownerAt(p);
    if (root == NONE) return float4(0.07, 0.08, 0.10, 1.0);

    float2 g = w.uv * float2(engine.size - 1);
    uint every = uint(max(wire, 2.0));
    bool onX = (uint(g.x) % every) == 0u && frac(g.x) < 0.35;
    bool onY = (uint(g.y) % every) == 0u && frac(g.y) < 0.35;
    if (!onX && !onY) discard;

    float3 tint = placeColor(centreOf(root) / float2(engine.size), 0.5);
    float lift = saturate(heightSmooth(w.uv) / 0.4);
    return float4(tint * (0.55 + 0.6 * lift), 1.0);
}
