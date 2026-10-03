// SHATTER: vacuum (demo D2). main_capture: one workgroup per visible batch; points close to the camera and inside
// the view cone are captured at random (the CPU adapts the probability so captures hit a target rate), marked
// collected, and spawned as particles. main_particles: one thread per particle slot; particles home in on a nozzle
// under the view with some swirl and are drawn as short streaks into the int64 accumulation buffer.

#pragma pack_matrix(row_major)
#include "PointCommon.hlsli"

ConstantBuffer<PointFrameConstants> g_Frame : register(b0);
StructuredBuffer<PointBatch>        t_Batches   : register(t0);
StructuredBuffer<uint>              t_Positions : register(t1);
StructuredBuffer<uint2>             t_Visible   : register(t2);
StructuredBuffer<uint>              t_Count     : register(t3);
RWStructuredBuffer<uint>            u_Collected : register(u0);
RWStructuredBuffer<PointParticle>   u_Particles : register(u1);
RWStructuredBuffer<uint64_t>        u_Vacuum    : register(u2);    // [0] collected total, [1] candidate weight this frame (x256), [2] particle head
RWStructuredBuffer<uint64_t>        u_Accum     : register(u3);

[numthreads(POINT_GROUP_SIZE, 1, 1)]
[WaveSize(32)]
void main_capture(uint3 groupId : SV_GroupID, uint tid : SV_GroupIndex)
{
    const uint visibleIndex = groupId.y * POINT_DISPATCH_ROW + groupId.x;
    if (visibleIndex >= t_Count[0])
        return;
    const PointBatch b = t_Batches[t_Visible[visibleIndex].x];

    const float3 cam = g_Frame.cameraPosAndNear.xyz;
    const float radius = g_Frame.vacuumUpAndRadius.w;
    const float3 nearest = clamp(cam, b.aabbMin, b.aabbMax);
    if (dot(nearest - cam, nearest - cam) > radius * radius)
        return; // uniform: almost every batch leaves here

    const float3 fwd = g_Frame.vacuumDirAndCos.xyz;
    const float cosCone = g_Frame.vacuumDirAndCos.w;
    const float captureScale = g_Frame.vacuumParams.x;
    const float3 quantum = (b.aabbMax - b.aabbMin) * kPointQuantumScale;

    uint weightSum = 0;
    uint captured = 0;
    for (uint s = tid; s < b.count; s += POINT_GROUP_SIZE)
    {
        const uint index = b.firstPoint + s;
        const uint bit = 1u << (index & 31u);
        if ((u_Collected[index >> 5] & bit) != 0)
            continue;
        // same position as PointRaster.hlsl
        const uint h = PcgHash(index ^ g_Frame.cloudSeed);
        const float3 p = b.aabbMin + (UnpackPointQuantized(t_Positions[index]) + HashToUnit3(PcgHash(h ^ 0x68E31DA4u))) * quantum;
        const float3 d = p - cam;
        const float dist = length(d);
        if (dist >= radius || dot(d, fwd) < cosCone * dist)
            continue;
        const float w = 1.0 - dist / radius; // closer points are favoured
        weightSum += uint(w * 256.0 + 0.5);
        const float u = HashToUnit(PcgHash(h ^ (g_Frame.frameIndex * 0x9E3779B9u) ^ 0x2C1B3C6Du));
        if (u >= captureScale * w)
            continue;
        uint old;
        InterlockedOr(u_Collected[index >> 5], bit, old);
        if ((old & bit) != 0)
            continue;
        captured++;
        uint64_t slot;
        InterlockedAdd(u_Vacuum[2], (uint64_t)1, slot);
        PointParticle q;
        q.position = p;
        q.age = 0.0;
        q.velocity = (HashToUnit3(PcgHash(h ^ 0x1B56C4E9u)) - 0.5) * 0.3;
        q.seed = h;
        u_Particles[uint(slot % POINT_PARTICLE_CAPACITY)] = q;
    }

    weightSum = WaveActiveSum(weightSum);
    captured = WaveActiveSum(captured);
    if (WaveIsFirstLane())
    {
        if (weightSum != 0) InterlockedAdd(u_Vacuum[1], (uint64_t)weightSum);
        if (captured != 0)  InterlockedAdd(u_Vacuum[0], (uint64_t)captured);
    }
}

#define STREAK_SAMPLES 4

[numthreads(POINT_PARTICLE_GROUP, 1, 1)]
void main_particles(uint3 dtid : SV_DispatchThreadID)
{
    PointParticle q = u_Particles[dtid.x];
    if (!(q.age >= 0.0))
        return; // dead (cleared to -1.0f)

    const float dt = g_Frame.vacuumParams.y;
    const float3 cam = g_Frame.cameraPosAndNear.xyz;
    const float3 fwd = g_Frame.vacuumDirAndCos.xyz;
    const float3 up = g_Frame.vacuumUpAndRadius.xyz;
    const float3 nozzle = cam + fwd * 0.4 - up * 0.15;

    const float3 to = nozzle - q.position;
    const float dist = length(to);
    const float3 dir = to / max(dist, 1e-4);
    const float spin = HashToUnit(PcgHash(q.seed ^ 0x7A3D9E21u)) * 2.0 - 1.0;
    const float3 swirl = cross(fwd, dir) * (spin * 1.2 * saturate(dist * 2.0));
    const float3 desired = dir * (0.5 + 3.0 * dist) + swirl;
    q.velocity = lerp(q.velocity, desired, 1.0 - exp(-6.0 * dt));

    const float3 prev = q.position;
    q.position += q.velocity * dt;
    q.age += dt;
    if (dist < 0.03 || q.age > 4.0)
    {
        q.age = -1.0;
        u_Particles[dtid.x] = q;
        return;
    }
    u_Particles[dtid.x] = q;

    const float zNear = g_Frame.cameraPosAndNear.w;
    const float minDistance2 = g_Frame.renderScaleAndBias.w * g_Frame.renderScaleAndBias.w;
    const float3 color = lerp(g_Frame.tintAndScale.rgb, HashToUnit3(PcgHash(q.seed ^ 0x51ED270Bu)) * 0.6 + 0.4, 0.5);
    [unroll]
    for (uint i = 0; i < STREAK_SAMPLES; i++)
    {
        const float3 p = lerp(prev, q.position, (float(i) + 0.5) / STREAK_SAMPLES);
        const float4 clip = mul(float4(p, 1.0), g_Frame.worldToClip);
        if (clip.w <= zNear)
            continue;
        const float2 pixel = (clip.xy / clip.w * float2(0.5, -0.5) + 0.5) * g_Frame.displaySizeAndInv.xy;
        if (any(pixel < 0.0) || any(pixel >= g_Frame.displaySizeAndInv.xy))
            continue;
        const float3 d = p - cam;
        // vacuumParams.z: fixed-point units * m^2 for the whole streak
        const float3 units = color * (g_Frame.vacuumParams.z / (max(dot(d, d), minDistance2) * STREAK_SAMPLES));
        const float dither = HashToUnit(PcgHash(q.seed ^ (g_Frame.frameIndex * 0x9E3779B9u) ^ i));
        const uint3 c = min(uint3(units + dither), POINT_FIXED_POINT_MAX.xxx);
        const uint2 ip = uint2(pixel);
        InterlockedAdd(u_Accum[ip.y * g_Frame.sizes.x + ip.x], (uint64_t)c.x | ((uint64_t)c.y << 21) | ((uint64_t)c.z << 42));
    }
}
