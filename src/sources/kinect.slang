#include "../lib/field.slang"

static const uint DEPTH_WIDTH = 640;
static const uint DEPTH_HEIGHT = 480;

// The surface heights are measured against. Either a plane fitted to the frame,
// which needs no setup, or a captured reference frame, which also cancels the
// per-pixel error a plane cannot: lens distortion, fixed-pattern depth bias, and
// the box's own unevenness.
struct Ground { float a; float b; float c; float spread; float captured; }

RWStructuredBuffer<float> heights;
StructuredBuffer<uint> depth;
StructuredBuffer<uint> reference;
ConstantBuffer<Ground> ground;

[Param(1.0, 0.0, 3.0)]  uniform float height;
[Param(0.8, 0.0, 0.95)] uniform float smoothing;
[Param(0.5, 0.0, 1.0)]  uniform float cropX;
[Param(0.5, 0.0, 1.0)]  uniform float cropY;
[Param(0.9, 0.1, 1.0)]  uniform float cropSize;

uint indexOf(int2 p) {
    int2 q = clamp(p, int2(0), int2(DEPTH_WIDTH - 1, DEPTH_HEIGHT - 1));
    return uint(q.y) * DEPTH_WIDTH + uint(q.x);
}

// Frames arrive as little-endian uint16 millimetres, two samples per word.
uint millimetres(StructuredBuffer<uint> frame, int2 p) {
    uint i = indexOf(p);
    uint packed = frame[i >> 1];
    return (i & 1u) == 0u ? (packed & 0xFFFFu) : (packed >> 16);
}

// Single pixels flicker between a surface and whatever is behind it, and once a
// baseline is subtracted that flicker is the only signal left, so it spikes to
// full scale. A median throws it away where an average would smear it around.
float median3x3(StructuredBuffer<uint> frame, int2 p) {
    float window[9];
    int found = 0;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            uint s = millimetres(frame, p + int2(dx, dy));
            if (s != 0u) window[found++] = float(s);
        }
    }
    if (found == 0) return 0.0;

    for (int i = 1; i < found; i++) {
        float key = window[i];
        int j = i - 1;
        while (j >= 0 && window[j] > key) {
            window[j + 1] = window[j];
            j--;
        }
        window[j + 1] = key;
    }
    return window[found / 2];
}

// The IR emitter sits beside the camera, so steep slopes and box walls leave
// holes that read as zero. Widen the search, and report 0 if nothing resolves —
// shiny surfaces reflect the pattern away entirely and never will.
float filled(StructuredBuffer<uint> frame, int2 p) {
    float here = median3x3(frame, p);
    if (here != 0.0) return here;

    for (int r = 2; r <= 6; r++) {
        float sum = 0.0;
        float found = 0.0;
        for (int dy = -r; dy <= r; dy += r) {
            for (int dx = -r; dx <= r; dx += r) {
                uint n = millimetres(frame, p + int2(dx, dy));
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

    float live = filled(depth, p);
    if (live == 0.0) return;

    // Height is distance from the ground, not from the camera. A tilted sensor
    // spreads raw depth across a metre and swamps everything on the surface.
    float base;
    if (ground.captured > 0.5) {
        base = filled(reference, p);
        if (base == 0.0) return;
    } else {
        base = ground.a * float(p.x) + ground.b * float(p.y) + ground.c;
    }

    float target = clamp((base - live) / max(ground.spread, 1.0), -1.0, 1.0) * 0.5 * height;

    uint i = cellIndex(tid.xy);
    heights[i] = lerp(target, heights[i], smoothing);
}
