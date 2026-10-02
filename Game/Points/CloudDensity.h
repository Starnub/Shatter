// SHATTER: CPU side of point cloud generation (PLAN 4.1). Evaluates a cloud's density on a Morton-ordered grid and
// turns it into per-cell point offsets for Shaders/Points/PointGenerate.hlsl.
#pragma once

#include <cstdint>
#include <vector>

#include <donut/core/math/math.h>

namespace shatter
{
    struct CloudShape
    {
        donut::math::float3 center = donut::math::float3(0.f);
        float    radius = 1.f;           // m; the grid spans center +- kGridExtent * radius
        float    warp = 0.6f;            // domain-warp strength (fraction of radius)
        float    noiseFrequency = 1.5f;  // noise features per radius
        uint32_t seed = 1;
    };

    struct CloudDensityGrid
    {
        uint32_t gridLog2 = 7;
        donut::math::float3 gridMin = donut::math::float3(0.f);
        float    cellSize = 0.f;
        std::vector<uint32_t> cellOffsets; // cellCount + 1 entries; offsets[c] = first point of Morton cell c
    };

    // Noise-warped Gaussian body with FBm wisps. Multithreaded; ~2M cells at gridLog2 = 7.
    CloudDensityGrid BuildCloudDensityGrid(const CloudShape& shape, uint32_t gridLog2, uint32_t pointCount);

    // Must match MortonDecode3 in Shaders/Points/PointCommon.hlsli
    donut::math::uint3 MortonDecode3(uint32_t code);

    constexpr float kGridExtent = 1.6f;
}
