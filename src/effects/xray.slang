#include "../lib/surface.slang"
#include "../lib/labels.slang"

// Finds every hand in view and draws its bones. No model of a hand anywhere:
// a palm is the thickest point of an object, fingertips are the points furthest
// from it along the surface — measured in palm widths, which is what separates
// a finger from the palm's own edge, and a hand from a hemisphere — and each
// finger is the way back. Works with the fingers spread; a fist has none.

[Param(0.03, 0.0, 0.3)]  uniform float cutoff;
[Param(2.0, 1.2, 4.0)]   uniform float reach;
[Param(9.0, 3.0, 24.0)]  uniform float apart;
[Param(5.0, 2.0, 20.0)]  uniform float minPalm;

static const uint NONE = 0xFFFFFFFFu;
static const float FAR = 1e9;
static const uint MAX_TIPS = 16;
static const uint BONES_PER_FINGER = 5;
static const uint MAX_BONES = 96;
static const uint PALM_BONES = MAX_TIPS * BONES_PER_FINGER;

// claims slots: a counter and a list of fingertip cells, then two more counters
static const uint TIPS = 1;
static const uint PALM_LABELS = MAX_TIPS + 1;
static const uint PALM_DOTS = MAX_TIPS + 2;

struct Bone {
    float2 a;
    float2 b;
    float ha;
    float hb;
    uint shown;
    uint joint;
};

// Eight storage buffers is the most a stage may see by default, and heights is
// one of them, so thickness is written into the same buffer as the counts
// it replaces and every small counter lives in claims.
RWStructuredBuffer<Atomic<uint>> owner;
RWStructuredBuffer<Atomic<uint>> thickness;
RWStructuredBuffer<Atomic<uint>> palm;
RWStructuredBuffer<Atomic<uint>> claims;
RWStructuredBuffer<float> geo;
RWStructuredBuffer<Bone> bones;
[Snapshot("bones")] StructuredBuffer<Bone> skeleton;
[Labels] RWStructuredBuffer<Label> labels;

static const int2 AROUND[8] = {
    int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1),
    int2(1, 1), int2(-1, 1), int2(1, -1), int2(-1, -1),
};

bool outside(int2 p) { return any(p < int2(0)) || any(p >= int2(engine.size)); }
uint at(int2 p) { return uint(p.y) * engine.size.x + uint(p.x); }
int2 cellOfIndex(uint i) { return int2(int(i % engine.size.x), int(i / engine.size.x)); }
uint ownerAt(int2 p) { return outside(p) ? NONE : owner[at(p)].load(); }
bool sameObject(int2 p, uint root) { return root != NONE && ownerAt(p) == root; }
uint palmThickness(uint root) { return palm[root].load() >> 19; }
uint palmCell(uint root) { return palm[root].load() & 0x7FFFFu; }

// ---- find the objects ------------------------------------------------------

[shader("compute")]
[numthreads(8, 8, 1)]
void seed(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    owner[i].store(heightAt(int2(tid.xy)) > cutoff ? i : NONE);
    thickness[i].store(0xFFFFu);
    palm[i].store(0);
    claims[i].store(0);
    geo[i] = FAR;
    if (i < MAX_BONES) bones[i].shown = 0;
    if (i < MAX_LABELS) labels[i].shown = 0;
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
    for (int k = 0; k < 8; k++) {
        uint l = ownerAt(int2(tid.xy) + AROUND[k]);
        if (l != NONE) best = min(best, l);
    }
    if (best < self) {
        owner[self].min(best);
        owner[i].min(best);
    }
    uint root = owner[i].load();
    owner[i].min(owner[root].load());
}

// ---- each object's palm: its thickest point ----------------------------------

[shader("compute")]
[numthreads(8, 8, 1)]
void edge(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    int2 p = int2(tid.xy);
    uint root = ownerAt(p);
    if (root == NONE) return;
    for (int k = 0; k < 4; k++) {
        if (!sameObject(p + AROUND[k], root)) { thickness[at(p)].store(0); return; }
    }
}

[shader("compute")]
[numthreads(8, 8, 1)]
[Iterations(48)]
void thicken(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    int2 p = int2(tid.xy);
    uint root = ownerAt(p);
    if (root == NONE) return;
    uint best = thickness[at(p)].load();
    for (int k = 0; k < 4; k++) {
        int2 q = p + AROUND[k];
        if (sameObject(q, root)) best = min(best, thickness[at(q)].load() + 1u);
    }
    thickness[at(p)].store(best);
}

// Thickness in the high bits and index in the low, so one atomic max per object
// finds both its palm and how thick it is.
[shader("compute")]
[numthreads(8, 8, 1)]
void crown(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    int2 p = int2(tid.xy);
    uint root = ownerAt(p);
    if (root == NONE) return;
    palm[root].max((min(thickness[at(p)].load(), 4095u) << 19) | at(p));
}

// ---- fingers: furthest from the palm along the surface ----------------------

[shader("compute")]
[numthreads(8, 8, 1)]
void start(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint root = owner[i].load();
    if (root != NONE && palmCell(root) == i) geo[i] = 0.0;
}

[shader("compute")]
[numthreads(8, 8, 1)]
[Iterations(128)]
void spread(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    int2 p = int2(tid.xy);
    uint root = ownerAt(p);
    if (root == NONE) return;
    float best = geo[at(p)];
    for (int k = 0; k < 8; k++) {
        int2 q = p + AROUND[k];
        if (sameObject(q, root)) best = min(best, geo[at(q)] + (k < 4 ? 1.0 : 1.4142));
    }
    geo[at(p)] = best;
}

// A fingertip is a local maximum of distance-from-palm, at least `reach` palm
// widths out, on something thin, and clear of any other tip.
[shader("compute")]
[numthreads(8, 8, 1)]
void fingertips(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    int2 p = int2(tid.xy);
    uint root = ownerAt(p);
    if (root == NONE) return;

    float wide = float(palmThickness(root));
    if (wide < minPalm) return;
    float here = geo[at(p)];
    if (here >= FAR || here < reach * wide) return;

    int radius = int(apart);
    uint fattest = 0;
    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 q = p + int2(dx, dy);
            if ((dx == 0 && dy == 0) || !sameObject(q, root) || dx * dx + dy * dy > radius * radius) continue;
            float there = geo[at(q)];
            if (there > here || (there == here && at(q) < at(p))) return;
            fattest = max(fattest, thickness[at(q)].load());
        }
    }
    if (float(fattest) > 0.6 * wide) return;

    uint slot = claims[0].add(1u);
    if (slot < MAX_TIPS) claims[TIPS + slot].store(at(p));
}

// ---- bones: walk each finger back to the palm ---------------------------------

uint downhill(uint i, uint root) {
    int2 p = cellOfIndex(i);
    float here = geo[i];
    uint next = i;
    for (int k = 0; k < 8; k++) {
        int2 q = p + AROUND[k];
        if (!sameObject(q, root)) continue;
        float there = geo[at(q)];
        if (there < here) { here = there; next = at(q); }
    }
    return next;
}

Bone segment(uint from, uint to, uint joint) {
    Bone bone;
    bone.a = float2(cellOfIndex(from));
    bone.b = float2(cellOfIndex(to));
    bone.ha = heightAt(cellOfIndex(from));
    bone.hb = heightAt(cellOfIndex(to));
    bone.shown = 1;
    bone.joint = joint;
    return bone;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void articulate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint finger = cellIndex(tid.xy);
    uint found = min(claims[0].load(), MAX_TIPS);
    if (finger >= found) return;

    uint tip = claims[TIPS + finger].load();
    uint root = owner[tip].load();
    float wide = float(palmThickness(root));
    uint fat = uint(0.6 * wide);

    // The finger is the thin part of the way back: walk down until the surface
    // gets fat, which is where it joins the palm. Once to measure it, once more
    // to place the joints at its thirds.
    uint here = tip;
    uint length = 0;
    for (int s = 0; s < 512; s++) {
        uint next = downhill(here, root);
        if (next == here || thickness[next].load() > fat) break;
        here = next;
        length++;
    }
    uint base = here;

    // The far edge of something round looks like a tip from up close, but it
    // turns fat within a fraction of a palm width. Withdraw the claim so it is
    // not counted either.
    if (float(length) < 0.8 * wide) {
        claims[TIPS + finger].store(NONE);
        return;
    }

    uint knuckle1 = tip;
    uint knuckle2 = tip;
    here = tip;
    for (uint s = 0; s < length; s++) {
        here = downhill(here, root);
        if (s + 1 == length / 3) knuckle1 = here;
        if (s + 1 == (2 * length) / 3) knuckle2 = here;
    }

    uint slot = finger * BONES_PER_FINGER;
    bones[slot] = segment(knuckle1, tip, 0);
    bones[slot + 1] = segment(knuckle2, knuckle1, 0);
    bones[slot + 2] = segment(base, knuckle2, 0);
    bones[slot + 3] = segment(palmCell(root), base, 0);
    bones[slot + 4] = segment(tip, tip, 1);
}

// One thread per hand — its palm cell — marks the palm and counts its fingers.
[shader("compute")]
[numthreads(8, 8, 1)]
void palms(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    uint root = owner[i].load();
    if (root == NONE || palmCell(root) != i || float(palmThickness(root)) < minPalm) return;

    uint fingers = 0;
    uint found = min(claims[0].load(), MAX_TIPS);
    for (uint f = 0; f < found; f++) {
        uint tip = claims[TIPS + f].load();
        if (tip != NONE && owner[tip].load() == root) fingers++;
    }
    if (fingers == 0u) return;

    uint dot = claims[PALM_DOTS].add(1u);
    if (PALM_BONES + dot < MAX_BONES) bones[PALM_BONES + dot] = segment(i, i, 1);

    uint slot = claims[PALM_LABELS].add(1u);
    if (slot >= MAX_LABELS) return;
    Label label;
    label.cell = float2(cellOfIndex(i));
    label.height = heightAt(cellOfIndex(i));
    label.value = float(fingers);
    label.unit = UNIT_COUNT;
    label.line = 0;
    label.shown = 1;
    label.reserved = 0;
    labels[slot] = label;
}

// ---- draw ----------------------------------------------------------------------

struct Varying {
    float4 clip : SV_Position;
    float2 uv : UV;
    float kind : KIND;
    float2 shape : SHAPE;
};

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };

// A rigging bone: a kite from the joint at its head, out to the two side
// points a fifth of the way along, and tapering to the tail. (along, across)
static const float2 KITE[6] = {
    float2(0.0, 0.0), float2(0.2, -1.0), float2(1.0, 0.0),
    float2(0.0, 0.0), float2(1.0, 0.0), float2(0.2, 1.0),
};
static const float2 SQUARE[6] = {
    float2(-1, -1), float2(1, -1), float2(-1, 1),
    float2(1, -1), float2(1, 1), float2(-1, 1),
};

// Nine vertices per cell: six for its surface quad and three for a spare
// triangle. Triangles are assembled from consecutive vertices, so the spares
// must come in whole threes — two cells' spares make one bone. A mixed
// triangle would not be dropped but clipped, leaving slivers across the view.
[shader("vertex")]
[PerCell(9)]
Varying vertexMain(uint vid: SV_VertexID) {
    uint cell = vid / 9;
    uint sub = vid % 9;

    Varying o;
    o.clip = CULLED;
    o.uv = float2(0.0);
    o.kind = 0.0;
    o.shape = float2(0.0);

    if (sub < 6) {
        uint2 origin = uint2(cell % engine.size.x, cell / engine.size.x);
        if (any(origin >= engine.size - 1)) return o;
        uint2 p = origin + QUAD[sub];
        o.clip = project(cellWorld(p, heightAt(int2(p))));
        o.uv = float2(p) / float2(engine.size - 1);
        return o;
    }

    uint index = cell / 2;
    uint corner = (cell % 2) * 3 + (sub - 6);
    if (index >= MAX_BONES) return o;
    Bone bone = skeleton[index];
    if (bone.shown == 0u) return o;

    float lift = 0.02;
    float4 a = project(cellWorld(uint2(bone.a), bone.ha + lift));
    float4 b = project(cellWorld(uint2(bone.b), bone.hb + lift));
    float unit = cellOnScreen().y;

    // Work where a pixel is square, then squash x back for clip.
    float2 sa = float2(a.x * engine.aspect, a.y);
    float2 sb = float2(b.x * engine.aspect, b.y);
    float2 point;

    if (bone.joint == 1u) {
        float2 s = SQUARE[corner];
        point = sa + s * unit * 1.6;
        o.kind = 2.0;
        o.shape = s;
    } else {
        float2 k = KITE[corner];
        float2 along = normalize(sb - sa + float2(1e-6, 0.0));
        float2 normal = float2(-along.y, along.x);
        point = lerp(sa, sb, k.x) + normal * k.y * unit * 2.4;
        o.kind = 1.0;
        o.shape = k;
    }

    o.clip = float4(point.x / engine.aspect, point.y, lerp(a.z, b.z, saturate(o.shape.x)) - 0.002, 1.0);
    return o;
}

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    if (v.kind > 1.5) {
        float r = length(v.shape);
        if (r > 1.0) discard;
        return float4(lerp(float3(0.9, 1.0, 1.0), float3(0.2, 0.6, 0.7), r * r), 1.0);
    }
    if (v.kind > 0.5) {
        // Bright spine, darker toward the kite's edges, like a lit octahedron.
        float rib = 1.0 - abs(v.shape.y);
        return float4(lerp(float3(0.15, 0.45, 0.55), float3(0.75, 1.0, 1.0), rib * rib), 1.0);
    }

    int2 p = cellOf(v.uv);
    if (ownerAt(p) == NONE) {
        return float4(float3(0.05, 0.06, 0.08) * (0.6 + 0.4 * shading(v.uv)), 1.0);
    }

    // Flesh: dark and glassy, brightest at grazing edges like a real x-ray.
    float3 normal = normalAt(v.uv);
    float edge = pow(1.0 - abs(orbit(normal).z), 2.0);
    float3 flesh = float3(0.10, 0.16, 0.24) + float3(0.25, 0.45, 0.55) * edge;
    return float4(flesh * (0.7 + 0.3 * shading(v.uv)), 1.0);
}
