#ifndef OT_SURFACE
#define OT_SURFACE

#include "field.slang"

StructuredBuffer<float> heights;

StructuredBuffer<float> rawHeights;

float heightAt(int2 p) { int2 q = clampCell(p); return heights[q.y * int(engine.size.x) + q.x]; }

float rawHeightAt(int2 p) { int2 q = clampCell(p); return rawHeights[q.y * int(engine.size.x) + q.x]; }

float2 fieldExtent() {
    return float2(engine.size) / float(max(engine.size.x, engine.size.y));
}

float3 pointWorld(float2 cell, float h) {
    float2 uv = cell / float2(engine.size - 1);
    float2 extent = fieldExtent();
    return float3((uv.x - 0.5) * extent.x, h * engine.heightScale, (uv.y - 0.5) * extent.y);
}

float3 cellWorld(uint2 p, float h) { return pointWorld(float2(p), h); }

float3 orbit(float3 p) {
    float cy = cos(engine.yaw), sy = sin(engine.yaw);
    float3 a = float3(p.x * cy - p.z * sy, p.y, p.x * sy + p.z * cy);
    float cp = cos(engine.pitch), sp = sin(engine.pitch);
    return float3(a.x, a.y * cp + a.z * sp, a.z * cp - a.y * sp);
}

float4 project(float3 world) {
    float3 r = orbit(world);
    return float4(r.x * engine.zoom / engine.aspect, r.y * engine.zoom, r.z * 0.25 + 0.5, 1.0);
}

float2 cellOnScreen() {
    float2 cell = fieldExtent() / float2(engine.size - 1) * engine.zoom;
    return float2(cell.x / engine.aspect, cell.y);
}

static const float4 CULLED = float4(0.0, 0.0, 2.0, 1.0);

int2 cellOf(float2 uv) { return clampCell(int2(round(uv * float2(engine.size - 1)))); }

float heightSmooth(float2 uv) {
    float2 p = uv * float2(engine.size - 1);
    int2 i = int2(floor(p));
    float2 f = frac(p);
    float top = lerp(heightAt(i), heightAt(i + int2(1, 0)), f.x);
    float bottom = lerp(heightAt(i + int2(0, 1)), heightAt(i + int2(1, 1)), f.x);
    return lerp(top, bottom, f.y);
}

float3 normalAt(float2 uv) {
    float2 step = 1.0 / float2(engine.size - 1);
    float2 spacing = fieldExtent() * step;
    float gx = (heightSmooth(uv + float2(step.x, 0.0)) - heightSmooth(uv - float2(step.x, 0.0))) / (2.0 * spacing.x);
    float gz = (heightSmooth(uv + float2(0.0, step.y)) - heightSmooth(uv - float2(0.0, step.y))) / (2.0 * spacing.y);
    return normalize(float3(-gx * engine.heightScale, 1.0, -gz * engine.heightScale));
}

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
