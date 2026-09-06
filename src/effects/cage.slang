#include "../lib/surface.slang"
#include "../lib/components.slang"
#include "../lib/color.slang"
#include "../lib/labels.slang"

[Param(80.0, 4.0, 3000.0)] uniform float minCells;
[Param(6.0, 2.0, 24.0)]    uniform float wire;

static const float QUANTA = 4096.0;
static const uint MAX_ANCHORS = 8;
static const uint MAX_LINKS = MAX_ANCHORS * (MAX_ANCHORS - 1) / 2;
static const uint LINK_VERTICES = MAX_LINKS * 6;

void pairOf(uint k, out uint first, out uint second) {
    uint pair = 0;
    first = 0;
    second = 0;
    for (uint a = 0; a < MAX_ANCHORS; a++) {
        for (uint b = a + 1; b < MAX_ANCHORS; b++) {
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
}

struct Anchor {
    float2 centre;
    float height;
    float shown;
}

RWStructuredBuffer<Region> regions;
RWStructuredBuffer<Anchor> anchors;
[Snapshot("anchors")] StructuredBuffer<Anchor> ends;
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
    if (i < MAX_ANCHORS) anchors[i].shown = 0.0;
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
void anchor(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    if (owner[i].load() != i) return;
    if (float(regions[i].count.load()) < minCells) return;

    uint slot = taken[0].add(1u);
    if (slot >= MAX_ANCHORS) return;

    Anchor a;
    a.centre = centreOf(i);
    a.height = float(regions[i].peak.load()) / QUANTA;
    a.shown = 1.0;
    anchors[slot] = a;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void link(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint k = cellIndex(tid.xy);
    if (k >= MAX_LINKS) return;

    uint first, second;
    pairOf(k, first, second);
    Anchor from = anchors[first];
    Anchor to = anchors[second];
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
    labels[k] = label;
}

struct Wire {
    float4 clip : SV_Position;
    float2 uv : UV;
    float edge : EDGE;
};

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };
static const float2 CORNERS[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };

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
[Vertices(168)]
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
    uint first, second;
    pairOf(e / 6, first, second);
    Anchor from = ends[first];
    Anchor to = ends[second];
    if (from.shown < 0.5 || to.shown < 0.5) {
        o.clip = CULLED;
        return o;
    }
    o.clip = ribbon(pointWorld(from.centre, from.height), pointWorld(to.centre, to.height), CORNERS[e % 6], 0.0016);
    o.edge = 1.0;
    return o;
}

[shader("fragment")]
float4 fragmentMain(Wire w) : SV_Target {
    if (w.edge > 0.5) return float4(1.0, 1.0, 1.0, 1.0);

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
