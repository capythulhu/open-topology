#include "../lib/surface.slang"

// A wind tunnel over the field, in three dimensions. A 3D incompressible flow
// — advected, made divergence-free by a pressure relax — blows in from the
// left, with the terrain itself as the solid boundary, so the wind goes over
// what it can and around what it cannot. Streamlines seeded at several heights
// are integrated through it and drawn as ribbons coloured by speed.

[Param(1.4, 0.2, 4.0)]   uniform float wind;
[Param(32.0, 8.0, 48.0)] uniform float lines;
[Param(1.6, 0.8, 4.0)]   uniform float hot;

static const uint LAYERS = 16;
static const float THICK = 0.5 / float(LAYERS);
static const uint MAX_LINES = 48;
static const uint ROWS = 3;
static const uint STEPS = 160;
static const float STRIDE = 1.5;

// One column of voxels per cell, which is how a 3D grid fits a per-cell buffer.
struct Column { float4 v[LAYERS]; }
struct Scalars { float s[LAYERS]; }

RWStructuredBuffer<Column> velocity;
RWStructuredBuffer<Column> carried;
RWStructuredBuffer<Scalars> pressure;
RWStructuredBuffer<Scalars> divergence;
RWStructuredBuffer<float4> path;
[Snapshot("path")] StructuredBuffer<float4> curve;

bool insideXY(int2 p) { return all(p >= int2(0)) && all(p < int2(engine.size)); }
uint at(int2 p) { int2 q = clampCell(p); return uint(q.y) * engine.size.x + uint(q.x); }

// Below the ground is solid; so is everything under the floor.
bool solid(int3 v) {
    if (v.z < 0) return true;
    if (v.z >= int(LAYERS)) return false;
    return (float(v.z) + 0.5) * THICK < heightAt(v.xy);
}

// Off the left edge is the wind itself; off any other edge is the nearest
// cell, which is a slip wall on the sides and top and free outflow on the right.
float3 fieldAt(RWStructuredBuffer<Column> field, int3 v) {
    if (v.x < 0) return float3(wind, 0.0, 0.0);
    if (solid(v)) return float3(0.0);
    return field[at(v.xy)].v[clamp(v.z, 0, int(LAYERS) - 1)].xyz;
}

float3 fieldSmooth(RWStructuredBuffer<Column> field, float3 p) {
    int3 i = int3(floor(p));
    float3 f = frac(p);
    float3 c000 = fieldAt(field, i), c100 = fieldAt(field, i + int3(1, 0, 0));
    float3 c010 = fieldAt(field, i + int3(0, 1, 0)), c110 = fieldAt(field, i + int3(1, 1, 0));
    float3 c001 = fieldAt(field, i + int3(0, 0, 1)), c101 = fieldAt(field, i + int3(1, 0, 1));
    float3 c011 = fieldAt(field, i + int3(0, 1, 1)), c111 = fieldAt(field, i + int3(1, 1, 1));
    float3 low = lerp(lerp(c000, c100, f.x), lerp(c010, c110, f.x), f.y);
    float3 high = lerp(lerp(c001, c101, f.x), lerp(c011, c111, f.x), f.y);
    return lerp(low, high, f.z);
}

// Pressure past the right edge is zero, which is what lets the flow leave; a
// solid or any other edge reflects the cell's own pressure, which is what stops
// it passing through.
float pressureAt(int3 v, float own) {
    if (v.x >= int(engine.size.x)) return 0.0;
    if (v.x < 0 || !insideXY(v.xy) || v.z >= int(LAYERS) || solid(v)) return own;
    return pressure[at(v.xy)].s[v.z];
}

// Every voxel is drawn gently toward the free-stream wind. Left to the pressure
// solve alone the wind takes many seconds to cross the field; starting from the
// free stream leaves the solve only the local job of bending it over and
// around the terrain, which it does in a frame.
[shader("compute")]
[numthreads(8, 8, 1)]
void blow(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    for (int z = 0; z < int(LAYERS); z++) {
        float3 v = velocity[i].v[z].xyz;
        velocity[i].v[z] = float4(solid(int3(tid.xy, z)) ? float3(0.0) : lerp(v, float3(wind, 0.0, 0.0), 0.04), 0.0);
    }
}

[shader("compute")]
[numthreads(8, 8, 1)]
void advect(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    for (int z = 0; z < int(LAYERS); z++) {
        int3 here = int3(tid.xy, z);
        float3 from = float3(here) - velocity[i].v[z].xyz;
        carried[i].v[z] = float4(solid(here) ? float3(0.0) : fieldSmooth(velocity, from), 0.0);
    }
}

[shader("compute")]
[numthreads(8, 8, 1)]
void diverge(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    for (int z = 0; z < int(LAYERS); z++) {
        int3 p = int3(tid.xy, z);
        divergence[i].s[z] = 0.5 * (
            fieldAt(carried, p + int3(1, 0, 0)).x - fieldAt(carried, p + int3(-1, 0, 0)).x +
            fieldAt(carried, p + int3(0, 1, 0)).y - fieldAt(carried, p + int3(0, -1, 0)).y +
            fieldAt(carried, p + int3(0, 0, 1)).z - fieldAt(carried, p + int3(0, 0, -1)).z);
    }
}

[shader("compute")]
[numthreads(8, 8, 1)]
[Iterations(30)]
void relax(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    for (int z = 0; z < int(LAYERS); z++) {
        int3 p = int3(tid.xy, z);
        float own = pressure[i].s[z];
        float sum = pressureAt(p + int3(1, 0, 0), own) + pressureAt(p + int3(-1, 0, 0), own)
                  + pressureAt(p + int3(0, 1, 0), own) + pressureAt(p + int3(0, -1, 0), own)
                  + pressureAt(p + int3(0, 0, 1), own) + pressureAt(p + int3(0, 0, -1), own);
        pressure[i].s[z] = (sum - divergence[i].s[z]) / 6.0;
    }
}

[shader("compute")]
[numthreads(8, 8, 1)]
void project(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    for (int z = 0; z < int(LAYERS); z++) {
        int3 p = int3(tid.xy, z);
        if (solid(p)) { velocity[i].v[z] = float4(0.0); continue; }
        if (tid.x < 2) { velocity[i].v[z] = float4(wind, 0.0, 0.0, 0.0); continue; }
        float own = pressure[i].s[z];
        float3 gradient = 0.5 * float3(
            pressureAt(p + int3(1, 0, 0), own) - pressureAt(p + int3(-1, 0, 0), own),
            pressureAt(p + int3(0, 1, 0), own) - pressureAt(p + int3(0, -1, 0), own),
            pressureAt(p + int3(0, 0, 1), own) - pressureAt(p + int3(0, 0, -1), own));
        velocity[i].v[z] = float4(carried[i].v[z].xyz - gradient, 0.0);
    }
}

// One thread per streamline: seeded up the left edge in a few rows of height,
// stepped through the flow at a fixed stride. Each point keeps its speed, which
// is the colour and, at zero, the end of the line.
[shader("compute")]
[numthreads(8, 8, 1)]
void trace(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint n = cellIndex(tid.xy);
    uint across = uint(clamp(lines, 1.0, float(MAX_LINES)));
    if (n >= across * ROWS) return;

    uint row = n / across;
    uint column = n % across;
    float3 p = float3(
        1.0,
        (float(column) + 0.5) / float(across) * float(engine.size.y - 1),
        1.5 + float(row) * 4.5);
    bool alive = !solid(int3(round(p)));

    for (uint m = 0; m < STEPS; m++) {
        float3 v = fieldSmooth(velocity, p);
        float speed = length(v);
        if (speed < 0.02) alive = false;
        path[n * STEPS + m] = float4(p.xy, (p.z + 0.5) * THICK, alive ? speed : 0.0);
        if (!alive) continue;

        float3 v2 = fieldSmooth(velocity, p + normalize(v) * STRIDE * 0.5);
        if (length(v2) < 0.02) { alive = false; continue; }
        p += normalize(v2) * STRIDE;
        if (any(p.xy < float2(0.0)) || any(p.xy > float2(engine.size - 1)) || p.z < 0.0 || p.z > float(LAYERS) - 1.0) alive = false;
    }
}

struct Ribbon {
    float4 clip : SV_Position;
    float2 uv : UV;
    float arc : ARC;
    float speed : SPEED;
    float kind : KIND;
};

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };
static const float2 CORNERS[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };

[shader("vertex")]
[PerCell(6)]
[Vertices(137376)]
Ribbon vertexMain(uint vid: SV_VertexID) {
    Ribbon o;
    o.uv = float2(0.0);
    o.arc = 0.0;
    o.speed = 0.0;
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

    uint e = vid - cells * 6;
    uint segment = e / 6;
    uint line = segment / (STEPS - 1);
    uint step = segment % (STEPS - 1);
    float4 a = curve[line * STEPS + step];
    float4 b = curve[line * STEPS + step + 1];
    if (line >= uint(lines) * ROWS || a.w <= 0.0 || b.w <= 0.0) { o.clip = CULLED; return o; }

    float2 corner = CORNERS[e % 6];
    float4 from = project(pointWorld(a.xy, a.z));
    float4 to = project(pointWorld(b.xy, b.z));
    float2 dir = normalize((to.xy - from.xy) * float2(engine.aspect, 1.0) + 1e-6);
    float2 side = float2(-dir.y, dir.x) * 0.0022 * float2(1.0 / engine.aspect, 1.0);
    bool start = corner.x < 0.0;
    float4 base = start ? from : to;

    o.clip = float4(base.xy + side * corner.y, base.z - 0.002, 1.0);
    o.arc = float(start ? step : step + 1) * STRIDE;
    o.speed = start ? a.w : b.w;
    o.kind = 1.0;
    return o;
}

// Blue through cyan, green and yellow to red, as a wind tunnel would show it.
float3 heat(float t) {
    t = saturate(t) * 4.0;
    float3 stops[5] = {
        float3(0.10, 0.20, 0.90), float3(0.10, 0.85, 0.95), float3(0.25, 0.90, 0.30),
        float3(0.98, 0.90, 0.20), float3(0.95, 0.20, 0.10),
    };
    uint i = uint(t);
    return lerp(stops[min(i, 3u)], stops[min(i + 1u, 4u)], frac(t));
}

[shader("fragment")]
float4 fragmentMain(Ribbon r) : SV_Target {
    if (r.kind > 0.5) {
        float dash = 0.45 + 0.55 * smoothstep(0.3, 0.7, frac(r.arc * 0.09 - engine.time * wind * 0.6));
        return float4(heat(r.speed / (wind * hot)) * dash, 1.0);
    }
    return float4(float3(0.09, 0.10, 0.13) * (0.5 + 0.5 * shading(r.uv)), 1.0);
}
