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

// ---------------------------------------------------------------------------
// Particles — camera-facing billboards, additive blending. One instance per
// particle; the unit quad supplies the corner offsets.
// ---------------------------------------------------------------------------

struct ParticleInstance {       // matches ParticleInstanceGPU in BrawlerRenderer.mm
    float3 pos;
    float  size;
    float4 color;               // rgb premultiplied by fade, a = fade
};

struct ParticleUniforms {       // matches ParticleUniformsGPU in BrawlerRenderer.mm
    float4x4 vp;
    float3   camRight;
    float3   camUp;
};

struct ParticleOut {
    float4 position [[position]];
    float2 local;
    float4 color;
};

vertex ParticleOut particle_vertex(VertexIn in [[stage_in]],
                                   constant ParticleInstance *instances [[buffer(1)]],
                                   constant ParticleUniforms &u         [[buffer(2)]],
                                   uint iid [[instance_id]])
{
    ParticleInstance p = instances[iid];
    float3 world = p.pos + (u.camRight * in.position.x + u.camUp * in.position.y) * p.size;
    ParticleOut out;
    out.position = u.vp * float4(world, 1.0);
    out.local    = in.position.xy;
    out.color    = p.color;
    return out;
}

fragment float4 particle_fragment(ParticleOut in [[stage_in]]) {
    float r = length(in.local) * 2.0;
    float glow = smoothstep(1.0, 0.0, r);
    glow *= glow;                                  // hot core, fast falloff
    return float4(in.color.rgb * glow * in.color.a, 1.0); // additive: alpha unused
}
