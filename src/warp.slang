struct Warp {
    float2 offset;
    float2 scale;
    float angle;
    float aspect;
    float mirrorX;
    float mirrorY;
};

ConstantBuffer<Warp> warp;
Texture2D<float4> frame;
SamplerState smooth;

struct Corner {
    float4 clip : SV_Position;
    float2 screen;
};

[shader("vertex")]
Corner vertexMain(uint vid: SV_VertexID) {
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    Corner o;
    o.clip = float4(p, 0.0, 1.0);
    o.screen = p;
    return o;
}

[shader("fragment")]
float4 fragmentMain(Corner v) : SV_Target {
    float2 s = v.screen - warp.offset;
    s.x *= warp.aspect;
    float c = cos(warp.angle), n = sin(warp.angle);
    s = float2(c * s.x - n * s.y, n * s.x + c * s.y);
    s.x /= warp.aspect;
    s /= warp.scale;
    s *= float2(warp.mirrorX, warp.mirrorY);
    float2 uv = float2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
    float inside = all(uv >= 0.0) && all(uv <= 1.0) ? 1.0 : 0.0;
    return float4(frame.Sample(smooth, uv).rgb * inside, 1.0);
}
