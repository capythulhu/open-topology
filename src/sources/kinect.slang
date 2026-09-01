#include "../lib/field.slang"

static const uint DEPTH_WIDTH = 640;
static const uint DEPTH_HEIGHT = 480;

// A plane fitted to whatever is in frame, plus the spread of the deviations from
// it. Fitted per frame, so there is nothing to calibrate.
struct Ground { float a; float b; float c; float spread; }

RWStructuredBuffer<float> heights;
StructuredBuffer<uint> depth;
ConstantBuffer<Ground> ground;

[Param(1.0, 0.0, 3.0)]  uniform float height;
[Param(0.6, 0.0, 0.95)] uniform float smoothing;
[Param(0.5, 0.0, 1.0)]  uniform float cropX;
[Param(0.5, 0.0, 1.0)]  uniform float cropY;
[Param(0.9, 0.1, 1.0)]  uniform float cropSize;

uint indexOf(int2 p) {
    int2 q = clamp(p, int2(0), int2(DEPTH_WIDTH - 1, DEPTH_HEIGHT - 1));
    return uint(q.y) * DEPTH_WIDTH + uint(q.x);
}

// Frames arrive as little-endian uint16 millimetres, two samples per word.
uint millimetres(int2 p) {
    uint i = indexOf(p);
    uint packed = depth[i >> 1];
    return (i & 1u) == 0u ? (packed & 0xFFFFu) : (packed >> 16);
}

// The IR emitter sits beside the camera, so steep slopes and box walls leave
// holes that read as zero. Widen the search, and report 0 if nothing resolves —
// shiny surfaces reflect the pattern away entirely and never will.
float filled(int2 p) {
    uint here = millimetres(p);
    if (here != 0u) return float(here);

    for (int r = 1; r <= 6; r++) {
        float sum = 0.0;
        float found = 0.0;
        for (int dy = -r; dy <= r; dy += r) {
            for (int dx = -r; dx <= r; dx += r) {
                uint n = millimetres(p + int2(dx, dy));
                if (n != 0u) { sum += float(n); found += 1.0; }
            }
        }
        if (found > 0.0) return sum / found;
    }
    return 0.0;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void generate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;

    float2 uv = (float2(tid.xy) + 0.5) / float2(engine.size);
    float2 center = float2(cropX * float(DEPTH_WIDTH), cropY * float(DEPTH_HEIGHT));
    int2 p = int2(center + (uv - 0.5) * cropSize * float(DEPTH_HEIGHT));

    float live = filled(p);
    if (live == 0.0) return;

    // Height is distance from the fitted ground, not from the camera. A tilted
    // sensor spreads raw depth across a metre of range and swamps everything on
    // the surface; measuring against the plane cancels that entirely.
    float plane = ground.a * float(p.x) + ground.b * float(p.y) + ground.c;
    float target = clamp((plane - live) / max(ground.spread, 1.0), -1.0, 1.0) * 0.5 * height;

    uint i = cellIndex(tid.xy);
    heights[i] = lerp(target, heights[i], smoothing);
}
