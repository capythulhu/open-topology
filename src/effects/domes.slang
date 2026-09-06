#include "../lib/surface.slang"
#include "../lib/components.slang"

[Param(80.0, 4.0, 3000.0)] uniform float minCells;
[Param(1.0, 0.0, 3.0)]     uniform float speed;
[Param(1.1, 0.5, 2.0)]     uniform float fullness;

static const float QUANTA = 4096.0;
static const uint MAX_DOMES = 16;
static const uint PATTERNS = 6;
static const float PI = 3.14159265;

struct Region {
    Atomic<uint> count;
    Atomic<uint> sum;
    Atomic<uint> sumX;
    Atomic<uint> sumY;
}

struct Dome {
    float2 center;
    float radius;
    float height;
    uint pattern;
    uint live;
    uint pad0;
    uint pad1;
}

RWStructuredBuffer<Region> regions;
RWStructuredBuffer<uint> rankOf;
RWStructuredBuffer<Dome> domes;
[Snapshot("owner")]  StructuredBuffer<uint> owners;
[Snapshot("rankOf")] StructuredBuffer<uint> ranks;
[Snapshot("domes")]  StructuredBuffer<Dome> shapes;

[shader("compute")]
[numthreads(8, 8, 1)]
void reset(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    regions[i].count.store(0);
    regions[i].sum.store(0);
    regions[i].sumX.store(0);
    regions[i].sumY.store(0);
    rankOf[i] = NONE;
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
void shape(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    if (!qualifies(i)) return;

    uint rank = 0;
    for (uint j = 0; j < i; j++) if (qualifies(j)) rank++;
    if (rank >= MAX_DOMES) return;
    rankOf[i] = rank;

    float count = float(regions[i].count.load());
    Dome now;
    now.center = float2(regions[i].sumX.load(), regions[i].sumY.load()) / count;
    now.radius = sqrt(count / PI);
    now.height = 1.5 * float(regions[i].sum.load()) / QUANTA / count;
    now.pattern = rank % PATTERNS;
    now.live = 1;
    now.pad0 = 0;
    now.pad1 = 0;

    Dome was = domes[rank];
    if (was.live == 1 && distance(was.center, now.center) < was.radius) {
        now.center = lerp(was.center, now.center, 0.3);
        now.radius = lerp(was.radius, now.radius, 0.15);
        now.height = lerp(was.height, now.height, 0.15);
    }
    domes[rank] = now;
}

struct Varying {
    float4 clip : SV_Position;
    float2 local : LOCAL;
    float pattern : PATTERN;
    float dome : DOME;
}

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };

[shader("vertex")]
Varying vertexMain(uint vid: SV_VertexID) {
    uint columns = engine.size.x - 1;
    uint quad = vid / 6;
    uint2 p = uint2(quad % columns, quad / columns) + QUAD[vid % 6];
    uint i = cellIndex(p);

    Varying o;
    o.local = float2(0.0);
    o.pattern = 0.0;
    o.dome = 0.0;

    uint root = owners[i];
    for (int k = 0; k < 8 && root == NONE; k++) {
        int2 q = clampCell(int2(p) + int2(k % 3 - 1, k / 3 - 1) * 2);
        root = owners[cellIndex(uint2(q))];
    }
    uint rank = root == NONE ? NONE : ranks[root];
    float h = 0.0;
    if (rank != NONE) {
        Dome dome = shapes[rank];
        float reach = max(dome.radius * fullness, 1.0);
        float2 local = (float2(p) - dome.center) / reach;
        float rho = length(local);
        if (rho < 1.0) {
            h = dome.height * sqrt(1.0 - rho * rho) * smoothstep(1.0, 1.0 - 2.5 / reach, rho);
            o.local = local;
            o.pattern = float(dome.pattern);
            o.dome = 1.0;
        }
    }
    o.clip = project(cellWorld(p, h));
    return o;
}

float3 crosses(float u, float v, float t) {
    float2 g = float2(u * 6.0, v * 3.0 - t);
    float2 cell = floor(g);
    float2 f = frac(g);
    bool odd = (int(cell.x + cell.y) & 1) == 1;
    float3 a = float3(1.0, 0.85, 0.1), b = float3(0.9, 0.12, 0.08);
    float x = min(abs(f.x - f.y), abs(f.x + f.y - 1.0));
    return x < 0.12 ? (odd ? a : b) : (odd ? b : a);
}

float3 spiral(float u, float v, float t) {
    float s = frac(u * 3.0 + v * 4.0 - t);
    float band = smoothstep(0.45, 0.5, s) - smoothstep(0.95, 1.0, s);
    return lerp(float3(0.02, 0.10, 0.14), float3(0.1, 0.9, 0.85), band);
}

float3 rings(float u, float v, float t) {
    float s = frac(v * 5.0 - t * 1.5);
    float ring = pow(1.0 - s, 6.0);
    float3 glow = float3(1.0, 0.2, 0.8) * ring;
    return float3(0.08, 0.0, 0.12) + glow;
}

float3 diamonds(float u, float v, float t) {
    float a = u * 8.0 + v * 4.0 + t * 0.5;
    float b = u * 8.0 - v * 4.0 - t * 0.5;
    bool odd = ((int(floor(a)) + int(floor(b))) & 1) == 1;
    return odd ? float3(0.12, 0.3, 1.0) : float3(0.95, 0.95, 1.0);
}

float3 dots(float u, float v, float t) {
    float2 g = float2(u * 8.0, v * 4.0);
    if ((int(floor(g.y)) & 1) == 1) g.x += 0.5;
    float2 f = frac(g) - 0.5;
    float r = 0.28 + 0.1 * sin(t * 4.0 + floor(g.y) + floor(g.x));
    return length(f) < r ? float3(1.0, 0.55, 0.05) : float3(0.3, 0.05, 0.5);
}

float3 globe(float u, float v, float t) {
    float meridian = abs(frac(u * 12.0 + t * 0.3) - 0.5);
    float parallel = abs(frac(v * 6.0) - 0.5);
    float wire = max(smoothstep(0.42, 0.47, meridian), smoothstep(0.42, 0.47, parallel));
    return lerp(float3(0.02, 0.08, 0.04), float3(0.3, 1.0, 0.4), wire);
}

float3 paint(uint pattern, float u, float v, float t) {
    switch (pattern) {
    case 0: return crosses(u, v, t);
    case 1: return spiral(u, v, t);
    case 2: return rings(u, v, t);
    case 3: return diamonds(u, v, t);
    case 4: return dots(u, v, t);
    default: return globe(u, v, t);
    }
}

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    if (v.dome < 0.5) return float4(0.06, 0.07, 0.09, 1.0);

    float rho = min(length(v.local), 1.0);
    float u = atan2(v.local.y, v.local.x) / (2.0 * PI) + 0.5;
    float polar = asin(rho) / (PI * 0.5);
    float t = engine.time * speed;

    float3 color = paint(uint(round(v.pattern)), u, polar, t);
    if (flatView()) return float4(color, 1.0);

    float3 normal = normalize(float3(v.local.x, sqrt(max(1.0 - rho * rho, 0.0)) * 1.5, v.local.y));
    float lit = 0.55 + 0.45 * saturate(dot(normal, normalize(float3(0.35, 1.0, 0.25))));
    return float4(color * lit, 1.0);
}
