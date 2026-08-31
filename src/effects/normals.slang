#include "../lib/render.slang"

[Param(1.0, 0.0, 4.0)] uniform float strength;

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    float3 n = normalAt(cellOf(v.uv));
    n = normalize(float3(n.x * strength, n.y, n.z * strength));
    return float4(n * 0.5 + 0.5, 1.0);
}
