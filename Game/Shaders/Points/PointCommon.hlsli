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

// Ambient drift (visual only; capture tests rest positions): a slow, smooth current (a few sines of position and
// time, so neighbours move together) plus a small per-point wander. t: seconds, amp: metres.
float3 DriftPoint(float3 p, uint h, float t, float amp)
{
    const float3 q = p * 4.0;
    float3 drift;
    drift.x = sin(q.y + t * 0.37) + sin(q.z * 1.3 - t * 0.23);
    drift.y = sin(q.z + t * 0.31) + sin(q.x * 1.7 + t * 0.29);
    drift.z = sin(q.x + t * 0.41) + sin(q.y * 1.1 - t * 0.33);
    const float phase = HashToUnit(PcgHash(h ^ 0x3C6EF372u)) * 6.2831853;
    const float3 wander = float3(sin(t * 0.9 + phase), cos(t * 0.7 + phase * 1.3), sin(t * 0.8 + phase * 0.7));
    return p + drift * (0.5 * amp) + wander * (0.35 * amp);
}

// Cloud point brightness spread: log-uniform 0.25x..4x, mean 1. Shared by the raster and the vacuum particles.
float PointBrightness(uint h) { return exp2(HashToUnit(PcgHash(h ^ 0xB5297A4Du)) * 4.0 - 2.0) * 0.5411; }

static const float3 kPointQuantumScale = float3(1.0 / 2048.0, 1.0 / 2048.0, 1.0 / 1024.0);

#endif // SHATTER_POINT_COMMON_HLSLI
