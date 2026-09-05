#include "lib/surface.slang"

[Param(16.0, 0.0, 64.0)]  uniform float spacing;
[Param(0.0, -0.5, 0.5)]   uniform float level;

static const uint MAX_LINES = 256;
static const float WIDTH = 0.0022;

static const float2 CORNERS[6] = {
    float2(-1, -1), float2(1, -1), float2(-1, 1),
    float2(1, -1), float2(1, 1), float2(-1, 1),
};

struct Line { float4 clip : SV_Position; };

uint lineCell(uint index, uint count, uint every, uint last) {
    return index == count - 1 ? last : min(index * every, last);
}

[shader("vertex")]
[Vertices(1536)]
Line vertexMain(uint vid: SV_VertexID) {
    Line o;
    o.clip = CULLED;
    if (spacing < 1.0) return o;

    uint every = uint(spacing);
    uint2 last = engine.size - 1;
    uint alongX = min(last.x / every + 2, MAX_LINES / 2);
    uint alongY = min(last.y / every + 2, MAX_LINES / 2);

    uint line = vid / 6;
    if (line >= alongX + alongY) return o;

    float2 extent = fieldExtent();
    float2 corner = CORNERS[vid % 6];
    float y = level * engine.heightScale;
    float3 world;

    if (line < alongX) {
        float x = (float(lineCell(line, alongX, every, last.x)) / float(last.x) - 0.5) * extent.x;
        world = float3(x + corner.x * WIDTH, y, corner.y * 0.5 * extent.y);
    } else {
        float z = (float(lineCell(line - alongX, alongY, every, last.y)) / float(last.y) - 0.5) * extent.y;
        world = float3(corner.x * 0.5 * extent.x, y, z + corner.y * WIDTH);
    }

    o.clip = project(world);

    o.clip.z -= 0.0008;
    return o;
}

[shader("fragment")]
float4 fragmentMain(Line l) : SV_Target {
    return float4(0.13, 0.15, 0.19, 1.0);
}
