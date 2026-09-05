#include "../lib/surface.slang"

// A wind tunnel over the field. A 2D incompressible flow — advected, made
// divergence-free by a pressure relax — blows in from the left and parts around
// anything raised above `cutoff`, which is solid. Streamlines integrated through
// the result are draped over the surface as ribbons, with dashes running along
// them so the wind is seen to move.

[Param(0.03, 0.0, 0.5)]  uniform float cutoff;
[Param(1.4, 0.2, 4.0)]   uniform float wind;
[Param(48.0, 8.0, 64.0)] uniform float lines;
[Param(0.03, 0.0, 0.1)]  uniform float lift;

static const uint MAX_LINES = 64;
static const uint STEPS = 160;
static const float STRIDE = 1.5;

RWStructuredBuffer<float2> velocity;
RWStructuredBuffer<float2> carried;
RWStructuredBuffer<float> pressure;
RWStructuredBuffer<float> divergence;
RWStructuredBuffer<float4> path;
[Snapshot("path")] StructuredBuffer<float4> curve;

bool inside(int2 p) { return all(p >= int2(0)) && all(p < int2(engine.size)); }
bool solid(int2 p) { return inside(p) && heightAt(p) > cutoff; }
uint at(int2 p) { int2 q = clampCell(p); return uint(q.y) * engine.size.x + uint(q.x); }

// Off the left edge is the wind itself, off the right is whatever is leaving,
// off the top and bottom is the neighbouring cell — inflow, outflow, and slip.
float2 flowAt(int2 p) {
    if (p.x < 0) return float2(wind, 0.0);
    if (solid(p)) return float2(0.0);
    return velocity[at(p)];
}

// Pressure past the right edge is zero, which is what lets the flow leave; a
// solid, or the top and bottom edges, reflects the cell's own pressure, which
// is what stops it passing through.
float pressureAt(int2 q, float own) {
    if (q.x >= int(engine.size.x)) return 0.0;
    if (!inside(q) || solid(q)) return own;
    return pressure[at(q)];
}

float2 flowSmooth(float2 p) {
    int2 i = int2(floor(p));
    float2 f = frac(p);
    float2 top = lerp(flowAt(i), flowAt(i + int2(1, 0)), f.x);
    float2 bottom = lerp(flowAt(i + int2(0, 1)), flowAt(i + int2(1, 1)), f.x);
    return lerp(top, bottom, f.y);
}

// Every cell is drawn gently toward the free-stream wind. Left to the pressure
// solve alone the wind takes many seconds to work its way across the field,
// since Jacobi carries long-range effects slowly; starting from the free stream
// leaves the solve only the local job of bending it around solids, which it
// does in a frame.
[shader("compute")]
[numthreads(8, 8, 1)]
void blow(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    velocity[i] = solid(int2(tid.xy)) ? float2(0.0) : lerp(velocity[i], float2(wind, 0.0), 0.04);
}

// Semi-Lagrangian: each cell takes the velocity from wherever the flow came from.
[shader("compute")]
[numthreads(8, 8, 1)]
void advect(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    float2 from = float2(tid.xy) - velocity[i];
    carried[i] = solid(int2(tid.xy)) ? float2(0.0) : flowSmooth(from);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void diverge(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    int2 p = int2(tid.xy);
    float2 r = solid(p + int2(1, 0)) ? float2(0.0) : carried[at(p + int2(1, 0))];
    float2 l = solid(p + int2(-1, 0)) ? float2(0.0) : carried[at(p + int2(-1, 0))];
    float2 d = solid(p + int2(0, 1)) ? float2(0.0) : carried[at(p + int2(0, 1))];
    float2 u = solid(p + int2(0, -1)) ? float2(0.0) : carried[at(p + int2(0, -1))];
    divergence[cellIndex(tid.xy)] = 0.5 * ((r.x - l.x) + (d.y - u.y));
}

// Jacobi in place: every cell averages its neighbours' pressure and subtracts
// the divergence.
[shader("compute")]
[numthreads(8, 8, 1)]
[Iterations(60)]
void relax(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    int2 p = int2(tid.xy);
    uint i = cellIndex(tid.xy);
    float own = pressure[i];
    float sum = pressureAt(p + int2(1, 0), own) + pressureAt(p + int2(-1, 0), own)
              + pressureAt(p + int2(0, 1), own) + pressureAt(p + int2(0, -1), own);
    pressure[i] = (sum - divergence[i]) * 0.25;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void project(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    int2 p = int2(tid.xy);
    uint i = cellIndex(tid.xy);
    if (solid(p)) { velocity[i] = float2(0.0); return; }
    if (tid.x < 2) { velocity[i] = float2(wind, 0.0); return; }
    float own = pressure[i];
    float r = pressureAt(p + int2(1, 0), own);
    float l = pressureAt(p + int2(-1, 0), own);
    float d = pressureAt(p + int2(0, 1), own);
    float u = pressureAt(p + int2(0, -1), own);
    velocity[i] = carried[i] - 0.5 * float2(r - l, d - u);
}

// One thread per streamline: seeded up the left edge, stepped through the flow
// at a fixed stride so dashes have an arc length to run along. A point that
// stalls or leaves the field ends the line.
[shader("compute")]
[numthreads(8, 8, 1)]
void trace(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint n = cellIndex(tid.xy);
    uint count = uint(clamp(lines, 1.0, float(MAX_LINES)));
    if (n >= count) return;

    float2 p = float2(1.0, (float(n) + 0.5) / float(count) * float(engine.size.y - 1));
    bool alive = true;
    for (uint m = 0; m < STEPS; m++) {
        path[n * STEPS + m] = float4(p, heightAt(int2(round(p))) + lift, alive ? 1.0 : 0.0);
        if (!alive) continue;

        float2 v = flowSmooth(p);
        float speed = length(v);
        if (speed < 0.02) { alive = false; continue; }
        float2 mid = p + normalize(v) * STRIDE * 0.5;
        float2 v2 = flowSmooth(mid);
        if (length(v2) < 0.02) { alive = false; continue; }
        p += normalize(v2) * STRIDE;
        if (any(p < float2(0.0)) || any(p > float2(engine.size - 1))) alive = false;
    }
}

struct Ribbon {
    float4 clip : SV_Position;
    float2 uv : UV;
    float arc : ARC;
    float kind : KIND;
};

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };
static const float2 CORNERS[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };

[shader("vertex")]
[PerCell(6)]
[Vertices(61056)]
Ribbon vertexMain(uint vid: SV_VertexID) {
    Ribbon o;
    o.uv = float2(0.0);
    o.arc = 0.0;
    o.kind = 0.0;

    uint cells = engine.size.x * engine.size.y;
    if (vid < cells * 6) {
        uint cell = vid / 6;
        uint2 origin = uint2(cell % engine.size.x, cell / engine.size.x);
        if (any(origin >= engine.size - 1)) { o.clip = CULLED; return o; }
        uint2 p = origin + QUAD[vid % 6];
        o.clip = project(cellWorld(p, heightAt(int2(p))));
        o.uv = float2(p) / float2(engine.size - 1);
        return o;
    }

    // MAX_LINES * (STEPS - 1) segments, each a screen-space ribbon between two
    // consecutive points of its streamline.
    uint e = vid - cells * 6;
    uint segment = e / 6;
    uint line = segment / (STEPS - 1);
    uint step = segment % (STEPS - 1);
    float4 a = curve[line * STEPS + step];
    float4 b = curve[line * STEPS + step + 1];
    if (line >= uint(lines) || a.w < 0.5 || b.w < 0.5) { o.clip = CULLED; return o; }

    float2 corner = CORNERS[e % 6];
    float4 from = project(pointWorld(a.xy, a.z));
    float4 to = project(pointWorld(b.xy, b.z));
    float2 dir = normalize((to.xy - from.xy) * float2(engine.aspect, 1.0) + 1e-6);
    float2 side = float2(-dir.y, dir.x) * 0.0022 * float2(1.0 / engine.aspect, 1.0);
    float4 base = corner.x < 0.0 ? from : to;

    o.clip = float4(base.xy + side * corner.y, base.z - 0.002, 1.0);
    o.arc = float(corner.x < 0.0 ? step : step + 1) * STRIDE;
    o.kind = 1.0;
    return o;
}

[shader("fragment")]
float4 fragmentMain(Ribbon r) : SV_Target {
    if (r.kind > 0.5) {
        // Dashes run along the arc length at the wind speed.
        float dash = 0.35 + 0.65 * smoothstep(0.3, 0.7, frac(r.arc * 0.09 - engine.time * wind * 0.6));
        return float4(float3(0.75, 0.92, 1.0) * dash, 1.0);
    }

    int2 p = cellOf(r.uv);
    float shade = shading(r.uv);
    if (solid(p)) return float4(float3(0.30, 0.32, 0.36) * shade, 1.0);
    return float4(float3(0.09, 0.10, 0.13) * (0.6 + 0.4 * shade), 1.0);
}
