#ifndef OT_RENDER
#define OT_RENDER

// The stock surface: the field as a shaded mesh. Effects that only want to
// colour it include this and write a fragment shader. Effects that want their
// own geometry include surface.slang instead and write both stages.
#include "surface.slang"

struct Varying {
    float4 clip : SV_Position;
    float2 uv : UV;
}

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };

[shader("vertex")]
Varying vertexMain(uint vid: SV_VertexID) {
    uint columns = engine.size.x - 1;
    uint quad = vid / 6;
    uint2 p = uint2(quad % columns, quad / columns) + QUAD[vid % 6];

    Varying o;
    o.clip = project(cellWorld(p, heightAt(int2(p))));
    o.uv = float2(p) / float2(engine.size - 1);
    return o;
}

#endif
