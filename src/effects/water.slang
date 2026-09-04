#include "../lib/render.slang"
#include "../lib/color.slang"

[Param(0.2, -0.5, 0.5)]    uniform float level;
[Param(0.08, 0.005, 0.5)]  uniform float fill;
[Param(0.18, 0.02, 0.6)]   uniform float flowRate;
[Param(60.0, 5.0, 300.0)]  uniform float fadeMm;

RWStructuredBuffer<float> water;
RWStructuredBuffer<float> settled;
RWStructuredBuffer<float4> flux;

static const int2 DIRS[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };

bool outside(int2 p) { return any(p < int2(0)) || any(p >= int2(engine.size)); }

uint at(int2 p) { int2 q = clampCell(p); return uint(q.y) * engine.size.x + uint(q.x); }

float depthAt(int2 p) { return outside(p) ? 0.0 : water[at(p)]; }

// What the water's own surface sits at: the sand plus whatever is standing on it.
float surfaceAt(int2 p) { return heightAt(p) + depthAt(p); }

// Water is drawn toward the level wherever the sand is below it, and drains where
// the sand rises above. The flow passes do the rest, so raising a dune under water
// pushes it off rather than teleporting it.
[shader("compute")]
[numthreads(8, 8, 1)]
void feed(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    float wanted = max(level - heightAt(int2(tid.xy)), 0.0);
    water[i] = max(water[i] + (wanted - water[i]) * fill, 0.0);
}

// Pipe model: every cell keeps an outflow to each neighbour, accelerated by the
// drop in surface height and damped so it settles instead of ringing.
[shader("compute")]
[numthreads(8, 8, 1)]
void flow(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);

    float here = surfaceAt(int2(tid.xy));
    float4 previous = flux[i];
    float4 next = float4(0.0);
    float leaving = 0.0;

    for (int k = 0; k < 4; k++) {
        int2 q = int2(tid.xy) + DIRS[k];
        if (outside(q)) continue;
        float value = max(previous[k] * 0.96 + (here - surfaceAt(q)) * flowRate, 0.0);
        next[k] = value;
        leaving += value;
    }

    // Never send away more than the cell is holding, or depths go negative and
    // the surface tears itself apart.
    if (leaving > water[i] && leaving > 0.0) next *= water[i] / leaving;
    flux[i] = next;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void advance(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);

    float4 mine = flux[i];
    float leaving = mine.x + mine.y + mine.z + mine.w;

    int2 p = int2(tid.xy);
    float arriving = 0.0;
    if (!outside(p + DIRS[0])) arriving += flux[at(p + DIRS[0])].y;
    if (!outside(p + DIRS[1])) arriving += flux[at(p + DIRS[1])].x;
    if (!outside(p + DIRS[2])) arriving += flux[at(p + DIRS[2])].w;
    if (!outside(p + DIRS[3])) arriving += flux[at(p + DIRS[3])].z;

    float updated = max(water[i] + arriving - leaving, 0.0);

    // Four-neighbour flux leaves an alternating checkerboard sitting in its null
    // space, which the specular then turns into glitter. A little viscosity is
    // the cheapest thing that removes it.
    float around = 0.25 * (depthAt(p + DIRS[0]) + depthAt(p + DIRS[1]) +
                           depthAt(p + DIRS[2]) + depthAt(p + DIRS[3]));
    settled[i] = lerp(updated, around, 0.12);
}

// Written to a second buffer and copied back, so no pass ever reads depths that
// another thread has already advanced.
[shader("compute")]
[numthreads(8, 8, 1)]
void commit(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    water[i] = settled[i];
}

// Shade against the water's surface, not the sand under it, so a pool reads flat
// and glassy even though the mesh beneath it is not.
float3 surfaceNormal(int2 p) {
    float2 spacing = fieldExtent() / float2(engine.size - 1);
    float gx = (surfaceAt(p + DIRS[0]) - surfaceAt(p + DIRS[1])) / (2.0 * spacing.x);
    float gz = (surfaceAt(p + DIRS[2]) - surfaceAt(p + DIRS[3])) / (2.0 * spacing.y);
    return normalize(float3(-gx * engine.heightScale, 1.0, -gz * engine.heightScale));
}

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    int2 p = cellOf(v.uv);
    float3 land = terrain(heightSmooth(v.uv)) * shading(v.uv);

    float depth = depthAt(p);
    if (depth <= 0.0002) return float4(land, 1.0);

    float3 light = normalize(float3(0.35, 1.0, 0.25));
    float3 normal = surfaceNormal(p);
    float lambert = 0.45 + 0.55 * saturate(dot(normal, light));
    float sparkle = pow(saturate(dot(normal, normalize(light + float3(0.0, 1.0, 0.0)))), 40.0);

    float sunk = saturate(depth * engine.heightMm / fadeMm);
    float3 tint = lerp(float3(0.16, 0.55, 0.62), float3(0.01, 0.09, 0.27), sunk);

    // Shallows stay translucent so the sand reads through them, and the shoreline
    // gets a little brightness where the two meet.
    float shore = (1.0 - sunk) * (1.0 - sunk);
    float3 rgb = lerp(land, tint * lambert, saturate(0.18 + sunk * 0.78));
    return float4(rgb + sparkle * 0.25 + shore * 0.06, 1.0);
}
