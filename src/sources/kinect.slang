#include "../lib/field.slang"

static const uint DEPTH_WIDTH = 640;
static const uint DEPTH_HEIGHT = 480;
static const float2 PRINCIPAL = float2(320.0, 240.0);

struct Ground { float a; float b; float c; float spread; float captured; }

RWStructuredBuffer<float> heights;
RWStructuredBuffer<float> rawHeights;
StructuredBuffer<uint> depth;
StructuredBuffer<uint> reference;
ConstantBuffer<Ground> ground;

[Param(1.0, 0.0, 3.0)]  uniform float height;
[Param(8.0, 0.0, 40.0)] uniform float deadzone;
[Param(0.8, 0.0, 0.95)] uniform float smoothing;
[Param(0.5, 0.0, 1.0)]  uniform float cropX;
[Param(0.5, 0.0, 1.0)]  uniform float cropY;
[Param(0.9, 0.1, 1.0)]  uniform float cropWidth;
[Param(0.9, 0.1, 1.0)]  uniform float cropHeight;

uint indexOf(int2 p) {
    int2 q = clamp(p, int2(0), int2(DEPTH_WIDTH - 1, DEPTH_HEIGHT - 1));
    return uint(q.y) * DEPTH_WIDTH + uint(q.x);
}

uint millimetres(StructuredBuffer<uint> frame, int2 p) {
    uint i = indexOf(p);
    uint packed = frame[i >> 1];
    return (i & 1u) == 0u ? (packed & 0xFFFFu) : (packed >> 16);
}

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

static const int STEPS = 10;
static const float STEP_MM = 20.0;

float2 raised(float2 footing, float lifted) {
    float depth = ground.a * footing.x + ground.b * footing.y + ground.c;
    return PRINCIPAL + (footing - PRINCIPAL) * depth / max(depth - lifted, 1.0);
}

float aboveAt(float2 footing, float lifted) {
    int2 p = int2(raised(footing, lifted));
    uint live = millimetres(depth, p);
    if (live == 0u) return 0.0;
    float base = ground.captured > 0.5
        ? float(millimetres(reference, p))
        : ground.a * float(p.x) + ground.b * float(p.y) + ground.c;
    if (base == 0.0) return 0.0;
    return max(base - float(live), 0.0);
}

bool sample(int2 p, out float live, out float base) {
    live = filled(depth, p);
    if (live == 0.0) return false;
    if (ground.captured > 0.5) {
        base = filled(reference, p);
        return base != 0.0;
    }
    base = ground.a * float(p.x) + ground.b * float(p.y) + ground.c;
    return true;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void generate(uint3 tid: SV_DispatchThreadID) {
    if (any(tid.xy >= engine.size)) return;

    float2 uv = (float2(tid.xy) + 0.5) / float2(engine.size);
    float2 center = float2(cropX * float(DEPTH_WIDTH), cropY * float(DEPTH_HEIGHT));

    float2 span = float2(cropWidth * float(DEPTH_WIDTH), cropHeight * float(DEPTH_HEIGHT));
    float2 footing = center + (uv - 0.5) * span;

    float low = 0.0, high = 0.0;
    bool crossed = false;
    for (int k = 1; k <= STEPS && !crossed; k++) {
        high = float(k) * STEP_MM;
        if (aboveAt(footing, high) < high) crossed = true; else low = high;
    }
    for (int k = 0; k < 4; k++) {
        float mid = (low + high) * 0.5;
        if (aboveAt(footing, mid) < mid) high = mid; else low = mid;
    }
    float live, base;
    if (!sample(int2(raised(footing, high)), live, base)) return;

    float deviation = base - live;
    float beyond = max(abs(deviation) - deadzone, 0.0);
    float target = clamp(sign(deviation) * beyond / max(ground.spread, 1.0), -1.0, 2.5) * 0.5 * height;

    uint i = cellIndex(tid.xy);
    rawHeights[i] = target;
    heights[i] = lerp(target, heights[i], smoothing);
}
