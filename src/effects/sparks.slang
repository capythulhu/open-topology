#include "../lib/surface.slang"

// Every raised cell becomes a glowing dot. The floor draws only a faint grid,
// made from the floor cells that happen to sit on a grid line — the rest are
// culled outright. Reads rawHeights, so a hand sweeping through leaves no trail.

[Param(0.03, 0.0, 0.3)]  uniform float cutoff;
[Param(0.8, 0.1, 3.0)]   uniform float size;
[Param(0.4, 0.0, 1.0)]   uniform float rise;
[Param(16.0, 4.0, 64.0)] uniform float grid;

struct Dot {
    float4 clip : SV_Position;
    float2 corner : CORNER;
    float lift : LIFT;
    float tile : TILE;
};

static const float2 CORNERS[6] = {
    float2(-1, -1), float2(1, -1), float2(-1, 1),
    float2(1, -1), float2(1, 1), float2(-1, 1),
};

[shader("vertex")]
[PerCell(6)]
Dot vertexMain(uint vid: SV_VertexID) {
    uint cell = vid / 6;
    uint2 p = uint2(cell % engine.size.x, cell / engine.size.x);
    float h = rawHeightAt(int2(p));

    Dot o;
    o.corner = CORNERS[vid % 6];
    o.lift = saturate((h - cutoff) / max(0.5 - cutoff, 0.01));
    o.tile = 0.0;

    if (h < cutoff) {
        // Lines fall on multiples of the spacing, which never lands on the far
        // edges, so those are drawn explicitly to close the border.
        uint every = uint(max(grid, 1.0));
        bool onLine = p.x % every == 0u || p.y % every == 0u;
        bool onEdge = p.x == engine.size.x - 1 || p.y == engine.size.y - 1;
        if (!onLine && !onEdge) {
            o.clip = CULLED;
            return o;
        }
        // A flat tile lying on the floor, not a billboard, so the grid stays put
        // on the ground as the camera orbits.
        float3 world = cellWorld(p, cutoff);
        world.xz += o.corner * fieldExtent() / float2(engine.size - 1) * 0.5;
        o.clip = project(world);
        o.tile = 1.0;
        return o;
    }

    // A billboard: project the cell, then push the corners out in screen space
    // so the dot faces the camera whatever the orbit is doing.
    float4 clip = project(cellWorld(p, h + o.lift * rise * 0.2));
    clip.xy += o.corner * cellOnScreen() * size * 0.5;
    o.clip = clip;
    return o;
}

[shader("fragment")]
float4 fragmentMain(Dot d) : SV_Target {
    if (d.tile > 0.5) return float4(0.13, 0.15, 0.19, 1.0);

    float r = length(d.corner);
    if (r > 1.0) discard;

    float3 ember = float3(0.95, 0.30, 0.08);
    float3 flame = float3(1.0, 0.92, 0.55);
    float glow = 1.0 - r * r;
    return float4(lerp(ember, flame, d.lift) * glow, 1.0);
}
