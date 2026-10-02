// SHATTER: adds the accumulated point radiance to the upscaled HDR scene color (before bloom and tone mapping)
// and clears the accumulation target for the next frame (PLAN 4.2 step 4).

#pragma pack_matrix(row_major)
#include "PointCommon.hlsli"

ConstantBuffer<PointFrameConstants> g_Frame : register(b0);
#if ATOMIC_FP16X4
RWTexture2D<float4>             u_Accum         : register(u0);
#else
RWStructuredBuffer<uint64_t>    u_Accum         : register(u0);
#endif
RWTexture2D<float4>             u_SceneColor    : register(u1);    // display resolution, linear scene radiance

[numthreads(POINT_COMPOSITE_TILE, POINT_COMPOSITE_TILE, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
    const uint2 pixel = dtid.xy;
    if (any(pixel >= g_Frame.sizes.xy))
        return;

#if ATOMIC_FP16X4
    const float3 radiance = u_Accum[pixel].rgb;
    if (all(radiance == 0.0))
        return;
    u_Accum[pixel] = 0.0;
#else
    const uint index = pixel.y * g_Frame.sizes.x + pixel.x;
    const uint64_t packed = u_Accum[index];
    if (packed == 0)
        return;
    u_Accum[index] = 0;
    const uint3 fixedRgb = uint3((uint)(packed & POINT_FIXED_CHANNEL_MAX),
                                 (uint)((packed >> 21) & POINT_FIXED_CHANNEL_MAX),
                                 (uint)(packed >> 42));
    const float3 radiance = float3(fixedRgb) * g_Frame.invFixedScale;
#endif

    float4 color = u_SceneColor[pixel];
    color.rgb += radiance;
    u_SceneColor[pixel] = color;
}
