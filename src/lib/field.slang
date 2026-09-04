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

// A fixed vertex count, for geometry that does not scale with the field at all.
[__AttributeUsage(_AttributeTargets.Function)]
struct VerticesAttribute { int n; }

// On a buffer of Label (see labels.slang): the runtime reads it back each frame
// and letters each shown entry onto the view at its position.
[__AttributeUsage(_AttributeTargets.Var)]
struct LabelsAttribute {}

// On a read-only buffer: a copy of the named read-write buffer, taken after the
// compute passes. A vertex shader may not read read-write storage at all, so
// this is how geometry gets built from something a compute pass produced.
[__AttributeUsage(_AttributeTargets.Var)]
struct SnapshotAttribute { string source; }

// heightMm is what a unit of height means in the real world and cellMm is the
// width of one field cell, so physical quantities — a contour interval, an area,
// a volume — can be stated in millimetres, cm², and mL.
struct Engine {
    uint2 size;
    float heightScale;
    float time;
    float yaw;
    float pitch;
    float zoom;
    float aspect;
    float heightMm;
    float cellMm;
}

ConstantBuffer<Engine> engine;

uint cellIndex(uint2 p) { return p.y * engine.size.x + p.x; }

int2 clampCell(int2 p) { return clamp(p, int2(0), int2(engine.size) - 1); }

#endif
