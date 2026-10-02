// SHATTER: point system layouts shared by C++ (Game/Points) and HLSL (Game/Shaders/Points). PLAN section 4.
// C++: include <donut/core/math/math.h> first.
#ifndef SHATTER_POINT_SHARED_H
#define SHATTER_POINT_SHARED_H

#define POINT_BATCH_SIZE            4096    // points per batch (PLAN 4.1)
#define POINT_GROUP_SIZE            256     // threads per batch workgroup (generate + raster)
#define POINT_POINTS_PER_THREAD     16      // POINT_BATCH_SIZE / POINT_GROUP_SIZE
#define POINT_MASK_WORDS_PER_BATCH  128     // POINT_BATCH_SIZE / 32 collected bits
#define POINT_DISPATCH_ROW          32768   // 2D dispatches: linear group = y * POINT_DISPATCH_ROW + x
#define POINT_CULL_GROUP_SIZE       128
#define POINT_COMPOSITE_TILE        8

#define POINT_FLAG_AGGREGATE        0x80000000u // visible entry: batch is small on screen, pre-aggregate in the wave
#define POINT_COUNT_MASK            0x7FFFFFFFu

#define POINT_FIXED_CHANNEL_MAX     0x1FFFFFu   // int64 accumulation: 21/21/22-bit RGB fixed point
#define POINT_FIXED_POINT_MAX       0xFFFFFu    // a single point never adds more than this per channel

#ifdef __cplusplus
namespace shatter
{
    using namespace donut::math;
#endif

    struct PointBatch                       // 32 bytes
    {
        float3 aabbMin;
        uint   count;                       // points in the batch (the last batch of a cloud may be partial)
        float3 aabbMax;
        uint   firstPoint;                  // index of the first point in the cloud's position buffer
    };

    struct PointGenerateConstants
    {
        float4 gridMinAndCellSize;          // xyz: world-space min corner of the density grid, w: cell size (m)
        uint   gridLog2;                    // (1 << gridLog2)^3 cells in Morton order
        uint   cellCount;
        uint   pointCount;
        uint   batchCount;
        uint   seed;
        float  jitterCells;                 // points spread over a box this many cells wide around their cell center
        uint   _pad0;
        uint   _pad1;
    };

    struct PointFrameConstants
    {
        float4x4 worldToClip;               // display view without jitter, reverse-Z infinite projection
        float4   cameraPosAndNear;          // xyz: camera, w: zNear
        float4   displaySizeAndInv;         // xy: display size, zw: 1 / display size
        float4   renderScaleAndBias;        // xy: render size / display size, z: relative linear depth bias, w: min distance (m)
        float4   tintAndScale;              // rgb: cloud tint, w: per-point intensity * (1 / pixel solid angle) [scene radiance * m^2]
        uint4    sizes;                     // x, y: display size, z, w: render size
        float    fixedScale;                // scene radiance -> int64 fixed-point units
        float    invFixedScale;
        float    maxPointsPerPixel;         // LOD density cap
        float    aggregateMaxPixels;        // batches whose screen extent is <= this use wave aggregation (0 = never)
        uint     batchCount;
        uint     lodEnabled;
        uint     frameIndex;
        uint     cloudSeed;
    };

#ifdef __cplusplus
    static_assert(sizeof(PointBatch) == 32, "PointBatch layout");
    static_assert(sizeof(PointGenerateConstants) % 16 == 0, "cbuffer size");
    static_assert(sizeof(PointFrameConstants) % 16 == 0, "cbuffer size");
}
#endif

#endif // SHATTER_POINT_SHARED_H
