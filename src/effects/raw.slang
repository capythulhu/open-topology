#include "../lib/render.slang"

// The field as it arrives: height straight to grey, no lighting, no smoothing.
// Floor is black, `top` is white. Useful for seeing what the source is actually
// producing before any effect has interpreted it.

[Param(0.5, 0.05, 1.0)] uniform float top;

[shader("fragment")]
float4 fragmentMain(Varying v) : SV_Target {
    float value = saturate(rawHeightAt(cellOf(v.uv)) / top);
    return float4(value, value, value, 1.0);
}
