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
// Floor — flat base color with subtle grid lines in world space, plus a soft
// radial darkening toward the room edges.
// ---------------------------------------------------------------------------

struct FloorUniforms {            // matches FloorUniformsGPU in BrawlerRenderer.mm
    float4x4 mvp;
    float4   baseColor;
    float4   lineColor;
    float2   center;              // room center (world)
    float2   size;                // room extents (world)
};

struct FloorOut {
    float4 position [[position]];
    float2 world;
    float4 base;
    float4 line;
    float2 center;
    float2 halfSize;
};

vertex FloorOut floor_vertex(VertexIn in [[stage_in]],
                             constant FloorUniforms& u [[buffer(1)]]) {
    FloorOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.world    = in.position.xy * u.size + u.center;
    out.base     = u.baseColor;
    out.line     = u.lineColor;
    out.center   = u.center;
    out.halfSize = u.size * 0.5;
    return out;
}

fragment float4 floor_fragment(FloorOut in [[stage_in]]) {
    // Grid every 125 world units, ~3 units thick, softened.
    const float cell = 125.0;
    float2 g  = abs(fract(in.world / cell + 0.5) - 0.5) * cell;
    float dist = min(g.x, g.y);
    float lineMix = 1.0 - smoothstep(1.0, 3.0, dist);

    float3 c = mix(in.base.rgb, in.line.rgb, lineMix * 0.6);

    // Vignette toward room edges grounds the arena in the void around it.
    float2 rel = abs(in.world - in.center) / in.halfSize; // 0 center → 1 edge
    float edge = smoothstep(0.55, 1.05, max(rel.x, rel.y));
    c *= (1.0 - 0.35 * edge);

    return float4(c, 1.0);
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
