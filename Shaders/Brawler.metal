#include <metal_stdlib>
using namespace metal;

// Placeholder vertex/fragment shaders.
// Will be replaced by 3D mesh + skeletal skinning pass (T3).

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant float4x4 &mvp [[buffer(1)]]) {
    VertexOut out;
    out.position = mvp * float4(in.position, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return float4(0.2, 0.6, 1.0, 1.0); // placeholder blue
}
