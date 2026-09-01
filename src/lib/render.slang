#ifndef OT_RENDER
#define OT_RENDER

#include "field.slang"

StructuredBuffer<float> heights;

float heightAt(int2 p) { int2 q = clampCell(p); return heights[q.y * int(engine.size.x) + q.x]; }

struct Varying {
    float4 clip : SV_Position;
    float2 uv : UV;
}

static const uint2 QUAD[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };

float3 orbit(float3 p) {
    float cy = cos(engine.yaw), sy = sin(engine.yaw);
    float3 a = float3(p.x * cy - p.z * sy, p.y, p.x * sy + p.z * cy);
    // Pitch turns the world the opposite way to the camera: get this sign wrong
    // and raising the pitch swings the view under the terrain, so height counts
    // as distance and peaks lose the depth test to valleys.
    float cp = cos(engine.pitch), sp = sin(engine.pitch);
    return float3(a.x, a.y * cp + a.z * sp, a.z * cp - a.y * sp);
}

[shader("vertex")]
Varying vertexMain(uint vid: SV_VertexID) {
    uint columns = engine.size.x - 1;
    uint quad = vid / 6;
    uint2 p = uint2(quad % columns, quad / columns) + QUAD[vid % 6];

    float2 uv = float2(p) / float2(engine.size - 1);
    float2 extent = fieldExtent();
    float3 world = float3(
        (uv.x - 0.5) * extent.x,
        heightAt(int2(p)) * engine.heightScale,
        (uv.y - 0.5) * extent.y);
    float3 r = orbit(world);

    Varying o;
    o.clip = float4(r.x * engine.zoom / engine.aspect, r.y * engine.zoom, r.z * 0.25 + 0.5, 1.0);
    o.uv = uv;
    return o;
}

// uv comes from the vertex shader as p / (size - 1), so undoing it uses the same
// span. Sampling against size instead lands half a cell off the geometry.
int2 cellOf(float2 uv) { return clampCell(int2(round(uv * float2(engine.size - 1)))); }

float heightSmooth(float2 uv) {
    float2 p = uv * float2(engine.size - 1);
    int2 i = int2(floor(p));
    float2 f = frac(p);
    float top = lerp(heightAt(i), heightAt(i + int2(1, 0)), f.x);
    float bottom = lerp(heightAt(i + int2(0, 1)), heightAt(i + int2(1, 1)), f.x);
    return lerp(top, bottom, f.y);
}

// The field keeps the aspect ratio of its resolution, scaled to sit inside a
// unit square, so a 4:3 grid renders as a 4:3 plane.
float2 fieldExtent() {
    return float2(engine.size) / float(max(engine.size.x, engine.size.y));
}

// Per pixel off the interpolated height, so shading matches the surface the
// vertex shader actually built rather than stepping once per cell. Gradients are
// per world unit, which is not the same as per cell once the field is not square.
float3 normalAt(float2 uv) {
    float2 step = 1.0 / float2(engine.size - 1);
    float2 spacing = fieldExtent() * step;
    float gx = (heightSmooth(uv + float2(step.x, 0.0)) - heightSmooth(uv - float2(step.x, 0.0))) / (2.0 * spacing.x);
    float gz = (heightSmooth(uv + float2(0.0, step.y)) - heightSmooth(uv - float2(0.0, step.y))) / (2.0 * spacing.y);
    return normalize(float3(-gx * engine.heightScale, 1.0, -gz * engine.heightScale));
}

// Dividing by fwidth keeps a contour one pixel wide whatever the slope does.
// Ground flattened to a constant has no derivative to divide by, and no contour
// crossing it either, so it draws no line rather than NaN or a solid fill.
float contourMask(float h, float interval, float width) {
    float f = h / interval;
    float slope = fwidth(f);
    if (slope < 1e-6) return 0.0;
    return 1.0 - smoothstep(width - 0.5, width + 0.5, abs(frac(f - 0.5) - 0.5) / slope);
}

float shading(float2 uv) {
    return 0.35 + 0.65 * saturate(dot(normalAt(uv), normalize(float3(0.35, 1.0, 0.25))));
}

#endif
