// SHATTER: helpers shared by the point shaders.
#ifndef SHATTER_POINT_COMMON_HLSLI
#define SHATTER_POINT_COMMON_HLSLI

#include "PointShared.h"

// PCG hash (Jarzynski & Olano, "Hash Functions for GPU Rendering", JCGT 2020)
uint PcgHash(uint v)
{
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float HashToUnit(uint h) { return float(h >> 8) * (1.0 / 16777216.0); }

float3 HashToUnit3(uint h)
{
    uint h1 = PcgHash(h);
    uint h2 = PcgHash(h1);
    return float3(HashToUnit(h), HashToUnit(h1), HashToUnit(h2));
}

// 3D Morton decode, 10 bits per axis. Must match MortonDecode3 in Game/Points/CloudDensity.cpp.
uint MortonCompact1By2(uint x)
{
    x &= 0x09249249u;
    x = (x ^ (x >> 2)) & 0x030c30c3u;
    x = (x ^ (x >> 4)) & 0x0300f00fu;
    x = (x ^ (x >> 8)) & 0xff0000ffu;
    x = (x ^ (x >> 16)) & 0x000003ffu;
    return x;
}

uint3 MortonDecode3(uint code)
{
    return uint3(MortonCompact1By2(code), MortonCompact1By2(code >> 1), MortonCompact1By2(code >> 2));
}

// Positions: 11/11/10-bit offsets inside the batch AABB (PLAN 4.1)
uint PackPointPosition(float3 unit01)
{
    uint3 q = min(uint3(unit01 * float3(2048.0, 2048.0, 1024.0)), uint3(2047u, 2047u, 1023u));
    return q.x | (q.y << 11) | (q.z << 22);
}

float3 UnpackPointQuantized(uint packed)
{
    return float3(packed & 2047u, (packed >> 11) & 2047u, packed >> 22);
}

static const float3 kPointQuantumScale = float3(1.0 / 2048.0, 1.0 / 2048.0, 1.0 / 1024.0);

#endif // SHATTER_POINT_COMMON_HLSLI
