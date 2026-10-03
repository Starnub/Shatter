// SHATTER: additive point raster at display resolution (PLAN 4.2 step 3). One workgroup per visible batch.
//
// Every point adds its radiance to its pixel: diamond dust is sparse and translucent, so radiance is summed
// instead of resolving a nearest point. Order independent, no sorting.
//   ATOMIC_FP16X4=0: 64-bit InterlockedAdd into a uint64 buffer, RGB as 21/21/22-bit fixed point with stochastic
//                    rounding (unbiased for points far below one fixed-point unit).
//   ATOMIC_FP16X4=1: NVAPI NvInterlockedAddFp16x4 into an RGBA16F texture (benchmark alternative).
// Batches flagged POINT_FLAG_AGGREGATE (small on screen, so many lanes hit the same pixel) first sum per pixel
// inside the wave (WaveMatch + WaveMultiPrefixSum) and issue one atomic per pixel per wave.
//
// M1 shading is a placeholder: tint with a hashed per-point brightness spread. Real glint optics are M2 (PLAN 4.3).

#pragma pack_matrix(row_major)
#include "PointCommon.hlsli"

#if ATOMIC_FP16X4
#define NV_SHADER_EXTN_SLOT u127
#define NV_SHADER_EXTN_REGISTER_SPACE space0
#include <NVAPI/nvHLSLExtns.h>
#endif

ConstantBuffer<PointFrameConstants> g_Frame : register(b0);
StructuredBuffer<PointBatch>    t_Batches       : register(t0);
StructuredBuffer<uint>          t_Positions     : register(t1);
StructuredBuffer<uint>          t_Collected     : register(t2);
StructuredBuffer<uint2>         t_Visible       : register(t3);
StructuredBuffer<uint>          t_Count         : register(t4);
Texture2D<float>                t_SceneDepth    : register(t5);    // render resolution, reverse-Z NDC depth, 0 = sky / invalid

#if ATOMIC_FP16X4
RWTexture2D<float4>             u_Accum         : register(u0);
#else
RWStructuredBuffer<uint64_t>    u_Accum         : register(u0);
#endif

#define NO_PIXEL 0xFFFFFFFFu

// Visual motion only (demo): collection and capture use the rest positions.
//  - drift: a slow, smooth current (a few sines of position and time, so neighbours move together) plus a small
//    per-point wander
//  - pull: while vacuuming, points within reach in front of the camera lean toward the nozzle and spiral slightly
//    around the view axis; a faint ripple travels inward along the funnel
float3 AnimatePoint(float3 p, uint h)
{
    const float t = g_Frame.motionParams.x;
    const float amp = g_Frame.motionParams.y;
    const float3 q = p * 4.0;
    float3 drift;
    drift.x = sin(q.y + t * 0.37) + sin(q.z * 1.3 - t * 0.23);
    drift.y = sin(q.z + t * 0.31) + sin(q.x * 1.7 + t * 0.29);
    drift.z = sin(q.x + t * 0.41) + sin(q.y * 1.1 - t * 0.33);
    const float phase = HashToUnit(PcgHash(h ^ 0x3C6EF372u)) * 6.2831853;
    const float3 wander = float3(sin(t * 0.9 + phase), cos(t * 0.7 + phase * 1.3), sin(t * 0.8 + phase * 0.7));
    p += drift * (0.5 * amp) + wander * (0.35 * amp);

    const float pull = g_Frame.motionParams.w;
    if (pull > 0.0)
    {
        const float3 cam = g_Frame.cameraPosAndNear.xyz;
        const float3 fwd = g_Frame.vacuumDirAndCos.xyz;
        const float3 nozzle = cam + fwd * 0.4 - g_Frame.vacuumUpAndRadius.xyz * 0.15;
        const float3 v = nozzle - p;
        const float dist = length(v);
        const float reach = g_Frame.motionParams.z;
        if (dist < reach)
        {
            const float3 fromCam = p - cam;
            const float front = saturate(dot(fromCam, fwd) / max(length(fromCam), 1e-4));
            const float falloff = (1.0 - dist / reach) * (1.0 - dist / reach);
            const float ripple = 0.85 + 0.15 * sin(dist * 25.0 + t * 8.0); // crests travel toward the nozzle
            const float w = pull * falloff * front * ripple;
            p += v * w + cross(fwd, v) * (w * 0.5);
        }
    }
    return p;
}

uint HighestLane(uint4 mask)
{
    if (mask.w != 0) return 96 + firstbithigh(mask.w);
    if (mask.z != 0) return 64 + firstbithigh(mask.z);
    if (mask.y != 0) return 32 + firstbithigh(mask.y);
    return firstbithigh(mask.x);
}

#if ATOMIC_FP16X4
typedef float3 Contribution;
void AccumulateContribution(uint pixelIndex, Contribution c)
{
    const uint2 pixel = uint2(pixelIndex % g_Frame.sizes.x, pixelIndex / g_Frame.sizes.x);
    NvInterlockedAddFp16x4(u_Accum, pixel, float4(c, 0.0));
}
Contribution MakeContribution(float3 radiance, float dither) { return radiance; }
#else
typedef uint3 Contribution;
void AccumulateContribution(uint pixelIndex, Contribution c)
{
    c = min(c, POINT_FIXED_CHANNEL_MAX.xxx); // wave sums can exceed one channel; saturate instead of carrying into the next
    const uint64_t packed = (uint64_t)c.x | ((uint64_t)c.y << 21) | ((uint64_t)c.z << 42);
    InterlockedAdd(u_Accum[pixelIndex], packed);
}
Contribution MakeContribution(float3 radiance, float dither)
{
    // stochastic rounding keeps billions of sub-unit contributions unbiased
    return min(uint3(radiance * g_Frame.fixedScale + dither), POINT_FIXED_POINT_MAX.xxx);
}
#endif

[numthreads(POINT_GROUP_SIZE, 1, 1)]
[WaveSize(32)]
void main(uint3 groupId : SV_GroupID, uint tid : SV_GroupIndex)
{
    const uint visibleIndex = groupId.y * POINT_DISPATCH_ROW + groupId.x;
    if (visibleIndex >= t_Count[0])
        return; // uniform for the whole group

    const uint2 entry = t_Visible[visibleIndex];
    const uint renderCount = entry.y & POINT_COUNT_MASK;
    const bool aggregate = (entry.y & POINT_FLAG_AGGREGATE) != 0;
    const PointBatch b = t_Batches[entry.x];

    const float3 quantum = (b.aabbMax - b.aabbMin) * kPointQuantumScale;
    const float lodWeight = (float)b.count / (float)renderCount;
    const float scale = g_Frame.tintAndScale.w * lodWeight;
    const float3 cameraPos = g_Frame.cameraPosAndNear.xyz;
    const float zNear = g_Frame.cameraPosAndNear.w;
    const float minDistance2 = g_Frame.renderScaleAndBias.w * g_Frame.renderScaleAndBias.w;
    const float depthBias = g_Frame.renderScaleAndBias.z;

    // every lane runs the same number of iterations, so the wave intrinsics below see full waves
    for (uint base = 0; base < renderCount; base += POINT_GROUP_SIZE)
    {
        const uint s = base + tid;
        uint pixelIndex = NO_PIXEL;
        Contribution contribution = (Contribution)0;

        if (s < renderCount)
        {
            const uint index = b.firstPoint + s;
            const bool collected = ((t_Collected[index >> 5] >> (index & 31u)) & 1u) != 0;
            // Independent hash streams per use. Sharing one (brightness = the y dither) put the bright points at
            // the top of every quantization cell: a sawtooth that aliased into horizontal bands wherever the cells
            // were close to a pixel.
            const uint h = PcgHash(index ^ g_Frame.cloudSeed);

            // dither inside the quantization cell so the 11/11/10-bit lattice never shows
            const float3 p = AnimatePoint(b.aabbMin + (UnpackPointQuantized(t_Positions[index]) + HashToUnit3(PcgHash(h ^ 0x68E31DA4u))) * quantum, h);
            const float4 clip = mul(float4(p, 1.0), g_Frame.worldToClip);

            if (!collected && clip.w > zNear)
            {
                const float2 ndc = clip.xy / clip.w;
                const float2 pixel = (ndc * float2(0.5, -0.5) + 0.5) * g_Frame.displaySizeAndInv.xy;
                if (all(pixel >= 0.0) && all(pixel < g_Frame.displaySizeAndInv.xy))
                {
                    const uint2 ip = uint2(pixel);
                    const float sceneZ = t_SceneDepth[uint2(pixel * g_Frame.renderScaleAndBias.xy)];
                    // reverse-Z infinite projection: linear depth = zNear / z_ndc; 0 means sky
                    const bool visible = (sceneZ <= 0.0) || (clip.w < (zNear / sceneZ) * (1.0 + depthBias));
                    if (visible)
                    {
                        const float3 d = p - cameraPos;
                        const float distance2 = max(dot(d, d), minDistance2);

                        // placeholder shading: log-uniform brightness spread (0.25x..4x) around the tint
                        const float brightness = exp2(HashToUnit(PcgHash(h ^ 0xB5297A4Du)) * 4.0 - 2.0) * 0.5411; // mean 1
                        const float3 radiance = g_Frame.tintAndScale.rgb * (brightness * scale / distance2);

                        const float dither = HashToUnit(PcgHash(h ^ (g_Frame.frameIndex * 0x9E3779B9u)));
                        contribution = MakeContribution(radiance, dither);
                        pixelIndex = ip.y * g_Frame.sizes.x + ip.x;
                    }
                }
            }
        }

        if (aggregate)
        {
            const uint4 sameMask = WaveMatch(pixelIndex);
            const Contribution prefix = WaveMultiPrefixSum(contribution, sameMask);
            if (pixelIndex != NO_PIXEL && WaveGetLaneIndex() == HighestLane(sameMask))
            {
                const Contribution total = prefix + contribution;
                if (any(total != (Contribution)0))
                    AccumulateContribution(pixelIndex, total);
            }
        }
        else if (pixelIndex != NO_PIXEL && any(contribution != (Contribution)0))
        {
            AccumulateContribution(pixelIndex, contribution);
        }
    }
}
