#ifndef OT_FIELD
#define OT_FIELD

[__AttributeUsage(_AttributeTargets.Var)]
struct ParamAttribute { float value; float lo; float hi; }

[__AttributeUsage(_AttributeTargets.Function)]
struct IterationsAttribute { int n; }

[__AttributeUsage(_AttributeTargets.Function)]
struct PointsAttribute {}

[__AttributeUsage(_AttributeTargets.Function)]
struct PerCellAttribute { int n; }

[__AttributeUsage(_AttributeTargets.Function)]
struct VerticesAttribute { int n; }

[__AttributeUsage(_AttributeTargets.Var)]
struct LabelsAttribute {}

[__AttributeUsage(_AttributeTargets.Var)]
struct SnapshotAttribute { string source; }

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
