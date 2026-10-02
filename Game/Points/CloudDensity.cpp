#include "CloudDensity.h"

#include <algorithm>
#include <cmath>
#include <thread>

#include "ThirdParty/FastNoiseLite.h"

using namespace donut::math;

namespace shatter
{
    static uint32_t Compact1By2(uint32_t x)
    {
        x &= 0x09249249u;
        x = (x ^ (x >> 2)) & 0x030c30c3u;
        x = (x ^ (x >> 4)) & 0x0300f00fu;
        x = (x ^ (x >> 8)) & 0xff0000ffu;
        x = (x ^ (x >> 16)) & 0x000003ffu;
        return x;
    }

    uint3 MortonDecode3(uint32_t code)
    {
        return uint3(Compact1By2(code), Compact1By2(code >> 1), Compact1By2(code >> 2));
    }

    CloudDensityGrid BuildCloudDensityGrid(const CloudShape& shape, uint32_t gridLog2, uint32_t pointCount)
    {
        gridLog2 = std::clamp(gridLog2, 4u, 9u);
        const uint32_t res = 1u << gridLog2;
        const uint32_t cellCount = res * res * res;

        CloudDensityGrid grid;
        grid.gridLog2 = gridLog2;
        grid.cellSize = 2.f * kGridExtent * shape.radius / float(res);
        grid.gridMin = shape.center - float3(kGridExtent * shape.radius);

        // FastNoiseLite's GetNoise/DomainWarp are const, so one instance per role is safe across threads
        FastNoiseLite warpX, warpY, warpZ, wisps;
        auto setup = [&](FastNoiseLite& n, int seedOffset, int octaves)
        {
            n.SetSeed(int(shape.seed) + seedOffset);
            n.SetNoiseType(FastNoiseLite::NoiseType_OpenSimplex2);
            n.SetFractalType(FastNoiseLite::FractalType_FBm);
            n.SetFractalOctaves(octaves);
            n.SetFrequency(shape.noiseFrequency);
        };
        setup(warpX, 101, 3);
        setup(warpY, 202, 3);
        setup(warpZ, 303, 3);
        setup(wisps, 404, 4);

        std::vector<float> density(cellCount);
        const float invRes = 1.f / float(res);

        auto evaluate = [&](uint32_t begin, uint32_t end)
        {
            for (uint32_t c = begin; c < end; c++)
            {
                const uint3 cell = MortonDecode3(c);
                // normalized position in [-kGridExtent, kGridExtent]
                const float3 q = (float3(cell) + 0.5f) * invRes * (2.f * kGridExtent) - kGridExtent;

                const float3 w = q + shape.warp * float3(warpX.GetNoise(q.x, q.y, q.z),
                                                         warpY.GetNoise(q.x, q.y, q.z),
                                                         warpZ.GetNoise(q.x, q.y, q.z));
                const float body = std::exp(-2.5f * dot(w, w));
                float detail = std::clamp(0.55f + 0.6f * wisps.GetNoise(2.f * q.x, 2.f * q.y, 2.f * q.z), 0.f, 1.f);
                detail *= detail;
                density[c] = body * detail;
            }
        };

        const uint32_t threadCount = std::max(1u, std::thread::hardware_concurrency());
        const uint32_t chunk = (cellCount + threadCount - 1) / threadCount;
        std::vector<std::thread> threads;
        for (uint32_t t = 0; t < threadCount; t++)
        {
            const uint32_t begin = t * chunk;
            const uint32_t end = std::min(cellCount, begin + chunk);
            if (begin < end)
                threads.emplace_back(evaluate, begin, end);
        }
        for (std::thread& t : threads)
            t.join();

        // cumulative density -> integer offsets; exactly pointCount points in total, monotonic by construction
        double total = 0.0;
        for (float d : density)
            total += d;

        grid.cellOffsets.resize(size_t(cellCount) + 1);
        double running = 0.0;
        for (uint32_t c = 0; c < cellCount; c++)
        {
            const double fraction = (total > 0.0) ? running / total : double(c) / double(cellCount);
            grid.cellOffsets[c] = std::min(pointCount, uint32_t(std::floor(fraction * double(pointCount))));
            running += density[c];
        }
        grid.cellOffsets[cellCount] = pointCount;
        return grid;
    }
}
