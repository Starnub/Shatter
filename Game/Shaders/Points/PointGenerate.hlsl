// SHATTER: point cloud generation (PLAN 4.1). One workgroup per batch of 4096 points.
//
// The CPU evaluates the cloud's density on a Morton-ordered grid and turns it into per-cell point offsets
// (cumulative density, so the cloud has exactly pointCount points). Point g lives in the cell c with
// offsets[c] <= g < offsets[c+1]. Consecutive points are therefore spatially coherent without sorting a billion
// points, and every batch is a contiguous run of Morton cells.
//
// Inside a batch the storage order is a permutation of the generation order, so any prefix of a batch is a
// uniform subsample of it (prefix LOD). Positions are written as 11/11/10-bit offsets inside the batch AABB.

#pragma pack_matrix(row_major)
#include "PointCommon.hlsli"

ConstantBuffer<PointGenerateConstants> g_Gen : register(b0);
StructuredBuffer<uint>          t_CellOffsets   : register(t0);    // cellCount + 1 entries
RWStructuredBuffer<uint>        u_Positions     : register(u0);
RWStructuredBuffer<PointBatch>  u_Batches       : register(u1);
RWStructuredBuffer<uint>        u_Collected     : register(u2);    // 1 bit per point, POINT_MASK_WORDS_PER_BATCH words per batch

#define WAVE_COUNT (POINT_GROUP_SIZE / 32)
groupshared float3 gs_waveMin[WAVE_COUNT];
groupshared float3 gs_waveMax[WAVE_COUNT];

uint FindCell(uint g)
{
    // invariant: offsets[lo] <= g < offsets[hi]; offsets[0] = 0 and offsets[cellCount] = pointCount > g
    uint lo = 0;
    uint hi = g_Gen.cellCount;
    while (hi - lo > 1)
    {
        uint mid = (lo + hi) >> 1;
        if (t_CellOffsets[mid] <= g)
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}

// Each cell's points are scattered around its center with a quadratic B-spline kernel (sum of three uniforms per
// axis, support 3 cells), which reconstructs a C1-smooth density from the per-cell counts. A uniform box (what this
// did first) only sums to a staircase: the density steps showed up as vertical and horizontal bands.
float3 QuadraticBSplineOffset(uint h)
{
    const float3 a = HashToUnit3(h);
    const float3 b = HashToUnit3(PcgHash(h ^ 0x27D4EB2Fu));
    const float3 c = HashToUnit3(PcgHash(h ^ 0x165667B1u));
    return a + b + c - 1.5;
}

float3 GeneratePoint(uint g)
{
    uint cell = FindCell(g);
    float3 cellCoord = float3(MortonDecode3(cell));
    float3 local = 0.5 + QuadraticBSplineOffset(PcgHash(g ^ g_Gen.seed)) * g_Gen.jitterCells;
    return g_Gen.gridMinAndCellSize.xyz + (cellCoord + local) * g_Gen.gridMinAndCellSize.w;
}

[numthreads(POINT_GROUP_SIZE, 1, 1)]
[WaveSize(32)]
void main(uint3 groupId : SV_GroupID, uint tid : SV_GroupIndex)
{
    const uint batchIndex = groupId.y * POINT_DISPATCH_ROW + groupId.x;
    if (batchIndex >= g_Gen.batchCount)
        return; // uniform for the whole group

    const uint first = batchIndex * POINT_BATCH_SIZE;
    const uint count = min(POINT_BATCH_SIZE, g_Gen.pointCount - first);

    // gcd(4099, count) == 1 for every count <= 4096, so slot -> source index is a bijection on [0, count)
    const uint rotate = PcgHash(batchIndex ^ (g_Gen.seed * 0x9E3779B9u)) % count;

    float3 positions[POINT_POINTS_PER_THREAD];
    float3 localMin = 1e30;
    float3 localMax = -1e30;

    [unroll]
    for (uint k = 0; k < POINT_POINTS_PER_THREAD; k++)
    {
        const uint slot = k * POINT_GROUP_SIZE + tid;
        positions[k] = 0;
        if (slot < count)
        {
            const uint source = (slot * 4099u + rotate) % count;
            positions[k] = GeneratePoint(first + source);
            localMin = min(localMin, positions[k]);
            localMax = max(localMax, positions[k]);
        }
    }

    // batch AABB
    localMin = WaveActiveMin(localMin);
    localMax = WaveActiveMax(localMax);
    const uint wave = tid / 32;
    if (WaveIsFirstLane())
    {
        gs_waveMin[wave] = localMin;
        gs_waveMax[wave] = localMax;
    }
    GroupMemoryBarrierWithGroupSync();

    float3 aabbMin = gs_waveMin[0];
    float3 aabbMax = gs_waveMax[0];
    [unroll]
    for (uint w = 1; w < WAVE_COUNT; w++)
    {
        aabbMin = min(aabbMin, gs_waveMin[w]);
        aabbMax = max(aabbMax, gs_waveMax[w]);
    }
    const float3 invExtent = 1.0 / max(aabbMax - aabbMin, 1e-6);

    [unroll]
    for (uint k2 = 0; k2 < POINT_POINTS_PER_THREAD; k2++)
    {
        const uint slot = k2 * POINT_GROUP_SIZE + tid;
        if (slot < count)
            u_Positions[first + slot] = PackPointPosition(saturate((positions[k2] - aabbMin) * invExtent));
    }

    if (tid < POINT_MASK_WORDS_PER_BATCH)
        u_Collected[batchIndex * POINT_MASK_WORDS_PER_BATCH + tid] = 0;

    if (tid == 0)
    {
        PointBatch b;
        b.aabbMin = aabbMin;
        b.count = count;
        b.aabbMax = aabbMax;
        b.firstPoint = first;
        u_Batches[batchIndex] = b;
    }
}
