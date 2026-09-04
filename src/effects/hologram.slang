#include "../lib/surface.slang"

// The raised surface as a glowing mesh, trailing an afterimage of where it has
// been. Reads rawHeights so the live surface is sharp; the trail is its own
// buffer, decaying each frame, so it lingers rather than smears.

[Param(0.03, 0.0, 0.3)]   uniform float cutoff;
[Param(0.98, 0.8, 0.995)]  uniform float linger;
[Param(1.2, 0.0, 3.0)]    uniform float rim;

RWStructuredBuffer<float> afterglow;

// The vertex stage may not read read-write storage, so the geometry is built
// from a snapshot of the trail taken after remember() has run.
[Snapshot("afterglow")] StructuredBuffer<float> trail;

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };

float glowAt(int2 p) { int2 q = clampCell(p); return trail[q.y * int(engine.size.x) + q.x]; }

// Whatever is there now, or a fading memory of what was — whichever is higher.
[shader("compute")]
[numthreads(8, 8, 1)]
void remember(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;
    uint i = cellIndex(tid.xy);
    float now = max(rawHeightAt(int2(tid.xy)), 0.0);
    afterglow[i] = max(now, afterglow[i] * linger);
}

struct Face {
    float4 clip : SV_Position;
    float2 uv : UV;
};

[shader("vertex")]
Face vertexMain(uint vid: SV_VertexID) {
    uint columns = engine.size.x - 1;
    uint quad = vid / 6;
    uint2 origin = uint2(quad % columns, quad / columns);

    Face o;
    o.uv = float2(0.0);

    // A quad with nothing raised in it draws nothing at all.
    float peak = max(max(glowAt(int2(origin)), glowAt(int2(origin) + int2(1, 0))),
                     max(glowAt(int2(origin) + int2(0, 1)), glowAt(int2(origin) + int2(1, 1))));
    if (peak < cutoff) {
        o.clip = CULLED;
        return o;
    }

    uint2 p = origin + QUAD[vid % 6];
    o.clip = project(cellWorld(p, glowAt(int2(p))));
    o.uv = float2(p) / float2(engine.size - 1);
    return o;
}

float glowSmooth(float2 uv) {
    float2 p = uv * float2(engine.size - 1);
    int2 i = int2(floor(p));
    float2 f = frac(p);
    float top = lerp(glowAt(i), glowAt(i + int2(1, 0)), f.x);
    float bottom = lerp(glowAt(i + int2(0, 1)), glowAt(i + int2(1, 1)), f.x);
    return lerp(top, bottom, f.y);
}

float3 glowNormal(float2 uv) {
    float2 step = 1.0 / float2(engine.size - 1);
    float2 spacing = fieldExtent() * step;
    float gx = (glowSmooth(uv + float2(step.x, 0.0)) - glowSmooth(uv - float2(step.x, 0.0))) / (2.0 * spacing.x);
    float gz = (glowSmooth(uv + float2(0.0, step.y)) - glowSmooth(uv - float2(0.0, step.y))) / (2.0 * spacing.y);
    return normalize(float3(-gx * engine.heightScale, 1.0, -gz * engine.heightScale));
}

[shader("fragment")]
float4 fragmentMain(Face v) : SV_Target {
    int2 p = cellOf(v.uv);
    float memory = glowSmooth(v.uv);
    float now = max(rawHeightAt(p), 0.0);

    // How much of what is drawn here is trail rather than the surface itself.
    float ghost = 1.0 - saturate(now / max(memory, 1e-4));

    float3 normal = glowNormal(v.uv);
    float lambert = saturate(dot(normal, normalize(float3(0.35, 1.0, 0.25))));

    // orbit() is a pure rotation, so it takes a normal into view space, where
    // the camera looks straight down z and grazing angles have z near zero.
    float edge = pow(1.0 - abs(orbit(normal).z), 2.5);

    float lift = saturate(memory / 0.4);
    float3 live = lerp(float3(0.05, 0.70, 0.95), float3(0.85, 1.0, 1.0), lift);
    float3 faded = float3(0.50, 0.12, 0.80);
    float3 tint = lerp(live, faded, ghost);

    float3 rgb = tint * (0.18 + 0.42 * lambert) + tint * edge * rim;
    rgb *= 1.0 - ghost * 0.55;

    return float4(rgb, 1.0);
}
