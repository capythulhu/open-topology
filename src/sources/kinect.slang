#include "../lib/field.slang"

static const uint DEPTH_WIDTH = 640;
static const uint DEPTH_HEIGHT = 480;

RWStructuredBuffer<float> heights;
StructuredBuffer<uint> depth;

[Param(1500.0, 500.0, 4000.0)] uniform float basePlane;
[Param(300.0, 20.0, 1500.0)]   uniform float range;
[Param(0.35, 0.0, 1.0)]        uniform float amplitude;
[Param(0.6, 0.0, 0.95)]        uniform float smoothing;
[Param(0.5, 0.0, 1.0)]         uniform float cropX;
[Param(0.5, 0.0, 1.0)]         uniform float cropY;
[Param(0.9, 0.1, 1.0)]         uniform float cropSize;

// Frames arrive as little-endian uint16 millimetres, two samples per word.
uint depthAt(int2 p) {
    int2 q = clamp(p, int2(0), int2(DEPTH_WIDTH - 1, DEPTH_HEIGHT - 1));
    uint i = uint(q.y) * DEPTH_WIDTH + uint(q.x);
    uint word = depth[i >> 1];
    return (i & 1u) == 0u ? (word & 0xFFFFu) : (word >> 16);
}

// The IR emitter sits beside the camera, so steep slopes and box walls leave
// holes that read as zero. Widen the search until something valid turns up.
// Returns 0 when there is nothing to be had — shiny metal reflects the pattern
// away entirely and never resolves at any radius.
float millimetresAt(int2 p) {
    uint here = depthAt(p);
    if (here != 0u) return float(here);

    for (int r = 1; r <= 6; r++) {
        float sum = 0.0;
        float found = 0.0;
        for (int dy = -r; dy <= r; dy += r) {
            for (int dx = -r; dx <= r; dx += r) {
                uint n = depthAt(p + int2(dx, dy));
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
    float2 source = center + (uv - 0.5) * cropSize * float(DEPTH_HEIGHT);

    float millimetres = millimetresAt(int2(source));
    if (millimetres == 0.0) return;

    float target = (saturate((basePlane - millimetres) / range) - 0.5) * amplitude;

    uint i = cellIndex(tid.xy);
    heights[i] = lerp(target, heights[i], smoothing);
}
