#include <metal_stdlib>
using namespace metal;

// Matches DrawUniforms in GameViewController.mm — pushed via setVertexBytes:.
struct Uniforms {
    float4x4 mvp;
    float4   color;
};

struct VertexIn {
    float3 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant Uniforms& u [[buffer(1)]]) {
    VertexOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.color    = u.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
