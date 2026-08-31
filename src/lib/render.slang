#ifndef OT_RENDER
#define OT_RENDER

#include "field.slang"

StructuredBuffer<float> heights;

float heightAt(int2 p) { int2 q = clampCell(p); return heights[q.y * int(engine.size.x) + q.x]; }

float3 normalAt(int2 p) {
    float gx = (heightAt(p + int2(1, 0)) - heightAt(p + int2(-1, 0))) * float(engine.size.x) * 0.5;
    float gz = (heightAt(p + int2(0, 1)) - heightAt(p + int2(0, -1))) * float(engine.size.y) * 0.5;
    return normalize(float3(-gx * engine.heightScale, 1.0, -gz * engine.heightScale));
}

struct Varying {
    float4 clip : SV_Position;
    float2 uv : UV;
}

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };

float3 orbit(float3 p) {
    float cy = cos(engine.yaw), sy = sin(engine.yaw);
    float3 a = float3(p.x * cy - p.z * sy, p.y, p.x * sy + p.z * cy);
    float cp = cos(engine.pitch), sp = sin(engine.pitch);
    return float3(a.x, a.y * cp - a.z * sp, a.y * sp + a.z * cp);
}

[shader("vertex")]
Varying vertexMain(uint vid: SV_VertexID) {
    uint cells = engine.size.x - 1;
    uint quad = vid / 6;
    uint2 p = uint2(quad % cells, quad / cells) + QUAD[vid % 6];

    float2 uv = float2(p) / float2(engine.size - 1);
    float3 world = float3(uv.x - 0.5, heightAt(int2(p)) * engine.heightScale, uv.y - 0.5);
    float3 r = orbit(world);

    Varying o;
    o.clip = float4(r.x * engine.zoom / engine.aspect, r.y * engine.zoom, r.z * 0.25 + 0.5, 1.0);
    o.uv = uv;
    return o;
}

int2 cellOf(float2 uv) { return clampCell(int2(uv * float2(engine.size))); }

#endif
