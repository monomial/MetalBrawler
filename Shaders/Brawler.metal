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

// ---------------------------------------------------------------------------
// Blob shadow — soft dark circle under each character. Uses the same unit
// quad as the flat pipeline; quad-local xy (±0.5) becomes the falloff radius.
// Drawn with alpha blending, depth-write off.
// ---------------------------------------------------------------------------

struct ShadowOut {
    float4 position [[position]];
    float2 local;
    float  alpha;
};

vertex ShadowOut shadow_vertex(VertexIn in [[stage_in]],
                               constant Uniforms& u [[buffer(1)]]) {
    ShadowOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.local    = in.position.xy;   // unit quad: -0.5 … +0.5
    out.alpha    = u.color.a;        // overall shadow strength
    return out;
}

fragment float4 shadow_fragment(ShadowOut in [[stage_in]]) {
    float r = length(in.local) * 2.0;             // 0 center → 1 at quad edge
    float a = smoothstep(1.0, 0.45, r) * in.alpha; // soft edge, solid core
    return float4(0.0, 0.0, 0.0, a);
}
