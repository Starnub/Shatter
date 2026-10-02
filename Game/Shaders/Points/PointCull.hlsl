// SHATTER: per-batch culling and LOD for one cloud (PLAN 4.2 step 1).
//   main_cull:     one thread per batch: frustum test on the 8 AABB corners, screen-space footprint, density-capped
//                  LOD (prefix subsample with energy compensation in the raster), wave-aggregation flag.
//   main_finalize: one thread: turns the visible count into 2D indirect dispatch args for the raster.
// Hi-Z occlusion is left for the valley (M3); the raster depth-tests every point.

#pragma pack_matrix(row_major)
#include "PointCommon.hlsli"

ConstantBuffer<PointFrameConstants> g_Frame : register(b0);
StructuredBuffer<PointBatch>    t_Batches   : register(t0);
RWStructuredBuffer<uint2>       u_Visible   : register(u0);    // (batch index, render count | flags)
RWStructuredBuffer<uint>        u_Args      : register(u1);    // [0..2] dispatch args, [3] visible batch count
RWStructuredBuffer<uint64_t>    u_Stats     : register(u2);    // [0] points sent to raster, [1] visible batches (all clouds)
RWStructuredBuffer<uint>        u_Count     : register(u3);    // [0] visible batch count, read by the raster

[numthreads(POINT_CULL_GROUP_SIZE, 1, 1)]
void main_cull(uint3 dtid : SV_DispatchThreadID)
{
    const uint batchIndex = dtid.x;
    if (batchIndex >= g_Frame.batchCount)
        return;

    const PointBatch b = t_Batches[batchIndex];
    if (b.count == 0)
        return;

    const float zNear = g_Frame.cameraPosAndNear.w;
    uint outside = 0x1Fu; // a bit stays set only if all 8 corners are outside that plane
    bool behind = false;
    float2 ndcMin = 1e30;
    float2 ndcMax = -1e30;

    [unroll]
    for (uint i = 0; i < 8; i++)
    {
        const float3 corner = float3((i & 1) ? b.aabbMax.x : b.aabbMin.x,
                                     (i & 2) ? b.aabbMax.y : b.aabbMin.y,
                                     (i & 4) ? b.aabbMax.z : b.aabbMin.z);
        const float4 clip = mul(float4(corner, 1.0), g_Frame.worldToClip);

        uint cornerOutside = 0;
        cornerOutside |= (clip.x < -clip.w) ? 0x01u : 0u;
        cornerOutside |= (clip.x >  clip.w) ? 0x02u : 0u;
        cornerOutside |= (clip.y < -clip.w) ? 0x04u : 0u;
        cornerOutside |= (clip.y >  clip.w) ? 0x08u : 0u;
        cornerOutside |= (clip.z >  clip.w) ? 0x10u : 0u; // reverse-Z near plane (z_ndc <= 1)
        outside &= cornerOutside;

        if (clip.w <= zNear)
            behind = true;
        else
        {
            const float2 ndc = clip.xy / clip.w;
            ndcMin = min(ndcMin, ndc);
            ndcMax = max(ndcMax, ndc);
        }
    }

    if (outside != 0)
        return;

    float areaPixels;
    float maxExtentPixels;
    if (behind)
    {
        areaPixels = g_Frame.displaySizeAndInv.x * g_Frame.displaySizeAndInv.y;
        maxExtentPixels = 1e30;
    }
    else
    {
        const float2 extent = (clamp(ndcMax, -1.0, 1.0) - clamp(ndcMin, -1.0, 1.0)) * 0.5 * g_Frame.displaySizeAndInv.xy;
        areaPixels = max(extent.x * extent.y, 1.0);
        maxExtentPixels = max(extent.x, extent.y);
    }

    uint renderCount = b.count;
    if (g_Frame.lodEnabled != 0)
    {
        const float cap = ceil(areaPixels * g_Frame.maxPointsPerPixel);
        renderCount = (uint)min((float)b.count, max(cap, 64.0));
    }

    const uint flags = (maxExtentPixels <= g_Frame.aggregateMaxPixels) ? POINT_FLAG_AGGREGATE : 0u;

    uint slot;
    InterlockedAdd(u_Args[3], 1u, slot);
    u_Visible[slot] = uint2(batchIndex, renderCount | flags);

    const uint64_t waveSum = WaveActiveSum((uint64_t)renderCount);
    if (WaveIsFirstLane())
        InterlockedAdd(u_Stats[0], waveSum);
}

[numthreads(1, 1, 1)]
void main_finalize()
{
    const uint n = u_Args[3];
    u_Args[0] = min(n, (uint)POINT_DISPATCH_ROW);
    u_Args[1] = (n + POINT_DISPATCH_ROW - 1) / POINT_DISPATCH_ROW;
    u_Args[2] = 1;
    u_Count[0] = n;
    InterlockedAdd(u_Stats[1], (uint64_t)n);
}
