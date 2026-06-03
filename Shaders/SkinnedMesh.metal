#include <metal_stdlib>
using namespace metal;

constant int kMaxBones = 64;

struct SkinnedVertex {
    float3  position    [[attribute(0)]];
    float3  normal      [[attribute(1)]];
    float2  texcoord    [[attribute(2)]];
    ushort4 jointIdx    [[attribute(3)]];
    float4  jointWeight [[attribute(4)]];
};

struct SkinnedOut {
    float4 position [[position]];
    float3 worldNormal;
    float2 texcoord;
    float4 tint;     // faction color passed through
};

struct SkinnedUniforms {
    float4x4 mvp;
    float4   color;  // faction tint
};

vertex SkinnedOut skinned_vertex_main(
    SkinnedVertex in              [[stage_in]],
    constant float4x4 *bones     [[buffer(1)]],
    constant SkinnedUniforms &u  [[buffer(2)]])
{
    float4 pos = float4(in.position, 1.0);
    float4 nrm = float4(in.normal,   0.0);

    float4 skPos = float4(0.0);
    float4 skNrm = float4(0.0);

    for (int i = 0; i < 4; i++) {
        float w = in.jointWeight[i];
        if (w > 0.001) {
            uint j = in.jointIdx[i];
            skPos += w * (bones[j] * pos);
            skNrm += w * (bones[j] * nrm);
        }
    }

    SkinnedOut out;
    out.position    = u.mvp * skPos;
    out.worldNormal = normalize(skNrm.xyz);
    out.texcoord    = in.texcoord;
    out.tint        = u.color;
    return out;
}

fragment float4 skinned_fragment_main(
    SkinnedOut in                  [[stage_in]],
    texture2d<float> diffuseTex   [[texture(0)]],
    sampler           texSampler  [[sampler(0)]])
{
    // Sample character skin texture; fall back to white if texture is missing/1x1.
    float4 texColor = diffuseTex.sample(texSampler, in.texcoord);

    // Very subtle faction tint — character skin texture dominates.
    float3 base = mix(texColor.rgb, in.tint.rgb, 0.08);

    // Diffuse lighting with a fixed directional light.
    float3 lightDir = normalize(float3(0.5, 0.8, 1.0));
    float  diffuse  = saturate(dot(normalize(in.worldNormal), lightDir));
    float  shade    = 0.3 + 0.7 * diffuse;

    return float4(base * shade, 1.0);
}
