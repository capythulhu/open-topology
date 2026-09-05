#ifndef OT_COMPONENTS
#define OT_COMPONENTS

#include "field.slang"
#include "surface.slang"

#ifndef COMPONENT_THRESHOLD
[Param(0.03, 0.0, 0.3)] uniform float cutoff;
#define COMPONENT_THRESHOLD cutoff
#endif

static const uint NONE = 0xFFFFFFFFu;

RWStructuredBuffer<Atomic<uint>> owner;

uint ownerAt(int2 p) { return owner[p.y * int(engine.size.x) + p.x].load(); }

[shader("compute")]
[numthreads(8, 8, 1)]
void seed(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    owner[i].store(heightAt(int2(tid.xy)) > COMPONENT_THRESHOLD ? i : NONE);
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

#endif
