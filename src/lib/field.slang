#ifndef OT_FIELD
#define OT_FIELD

[__AttributeUsage(_AttributeTargets.Var)]
struct ParamAttribute { float value; float lo; float hi; }

[__AttributeUsage(_AttributeTargets.Function)]
struct IterationsAttribute { int n; }

// On a vertex entry point: draw as points rather than triangles, and how many
// vertices to issue per field cell. Without PerCell the count is the shared
// quad grid, (columns - 1) * (rows - 1) * 6.
[__AttributeUsage(_AttributeTargets.Function)]
struct PointsAttribute {}

[__AttributeUsage(_AttributeTargets.Function)]
struct PerCellAttribute { int n; }

// heightMm is what the -0.5..0.5 height range means in the real world, so
// physical settings like a contour interval can be written in millimetres.
struct Engine {
    uint2 size;
    float heightScale;
    float time;
    float yaw;
    float pitch;
    float zoom;
    float aspect;
    float heightMm;
}

ConstantBuffer<Engine> engine;

uint cellIndex(uint2 p) { return p.y * engine.size.x + p.x; }

int2 clampCell(int2 p) { return clamp(p, int2(0), int2(engine.size) - 1); }

#endif
