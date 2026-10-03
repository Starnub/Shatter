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
        q.velocity = 0.0; // leaves the cloud from rest
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

// The jar: held in the lower right of the view, axis along the view's up. Particles fly into its mouth.
struct Jar { float3 bottom; float3 axis; float3 right; float3 back; float height; float radius; };
Jar GetJar()
{
    const float3 cam = g_Frame.cameraPosAndNear.xyz;
    const float3 fwd = g_Frame.vacuumDirAndCos.xyz;
    const float3 up = g_Frame.vacuumUpAndRadius.xyz;
    Jar j;
    j.right = normalize(cross(fwd, up));
    j.axis = up;
    j.back = fwd;
    j.height = 0.14;
    j.radius = 0.045;
    j.bottom = cam + fwd * 0.55 + j.right * 0.2 - up * 0.21;
    return j;
}

// adds one point to the int64 accumulation buffer; intensity in fixed-point units * m^2
void DrawPoint(float3 p, float3 color, float intensity, uint seed)
{
    const float4 clip = mul(float4(p, 1.0), g_Frame.worldToClip);
    if (clip.w <= g_Frame.cameraPosAndNear.w)
        return;
    const float2 pixel = (clip.xy / clip.w * float2(0.5, -0.5) + 0.5) * g_Frame.displaySizeAndInv.xy;
    if (any(pixel < 0.0) || any(pixel >= g_Frame.displaySizeAndInv.xy))
        return;
    const float3 d = p - g_Frame.cameraPosAndNear.xyz;
    const float minDistance2 = g_Frame.renderScaleAndBias.w * g_Frame.renderScaleAndBias.w;
    const float3 units = color * (intensity / max(dot(d, d), minDistance2));
    const float dither = HashToUnit(PcgHash(seed ^ (g_Frame.frameIndex * 0x9E3779B9u)));
    const uint3 c = min(uint3(units + dither), POINT_FIXED_POINT_MAX.xxx);
    if (all(c == 0u))
        return;
    const uint2 ip = uint2(pixel);
    InterlockedAdd(u_Accum[ip.y * g_Frame.sizes.x + ip.x], (uint64_t)c.x | ((uint64_t)c.y << 21) | ((uint64_t)c.z << 42));
}

[numthreads(POINT_PARTICLE_GROUP, 1, 1)]
void main_particles(uint3 dtid : SV_DispatchThreadID)
{
    PointParticle q = u_Particles[dtid.x];
    if (!(q.age >= 0.0))
        return; // dead (cleared to -1.0f)

    const float dt = g_Frame.vacuumParams.y;
    const float3 fwd = g_Frame.vacuumDirAndCos.xyz;
    const Jar jar = GetJar();
    const float3 mouth = jar.bottom + jar.axis * jar.height;

    const float3 to = mouth - q.position;
    const float dist = length(to);
    const float3 dir = to / max(dist, 1e-4);
    const float spin = HashToUnit(PcgHash(q.seed ^ 0x7A3D9E21u)) * 2.0 - 1.0;
    const float3 swirl = cross(fwd, dir) * (spin * 0.6 * saturate(dist * 2.0));
    const float3 desired = dir * (0.3 + 1.5 * dist) + swirl;
    q.velocity = lerp(q.velocity, desired, 1.0 - exp(-2.5 * dt)); // gentle acceleration from rest

    const float3 prev = q.position;
    q.position += q.velocity * dt;
    q.age += dt;
    if (dist < 0.02 || q.age > 5.0)
    {
        q.age = -1.0;
        u_Particles[dtid.x] = q;
        return;
    }
    u_Particles[dtid.x] = q;

    // fades in over 0.3 s so the stream grows out of the cloud
    const float fade = smoothstep(0.0, 0.3, q.age);
    const float3 color = lerp(g_Frame.tintAndScale.rgb, HashToUnit3(PcgHash(q.seed ^ 0x51ED270Bu)) * 0.6 + 0.4, 0.5 * fade);
    [unroll]
    for (uint i = 0; i < STREAK_SAMPLES; i++)
        DrawPoint(lerp(prev, q.position, (float(i) + 0.5) / STREAK_SAMPLES), color, g_Frame.vacuumParams.z * fade / STREAK_SAMPLES, q.seed ^ i);
}

// Jar contents fill from the bottom with the collected total; a dim outline shows the glass.
[numthreads(POINT_PARTICLE_GROUP, 1, 1)]
void main_jar(uint3 dtid : SV_DispatchThreadID)
{
    const Jar jar = GetJar();
    const uint i = dtid.x;
    const uint h = PcgHash(i ^ 0x6A09E667u);
    const float t = g_Frame.motionParams.x;
    if (i < POINT_JAR_POINTS)
    {
        const float fill = saturate(float(u_Vacuum[0]) / max(g_Frame.vacuumParams.w, 1.0));
        if (float(i) >= fill * POINT_JAR_POINTS)
            return;
        // stratified heights: point i sits at the i-th slice, so the contents rise from the bottom
        const float y = (float(i) + HashToUnit(h)) / POINT_JAR_POINTS * jar.height * 0.97;
        const float angle = HashToUnit(PcgHash(h ^ 0xBB67AE85u)) * 6.2831853 + t * 0.15;
        const float r = sqrt(HashToUnit(PcgHash(h ^ 0x3C6EF372u))) * jar.radius * 0.94;
        const float3 p = jar.bottom + jar.axis * y + (jar.right * cos(angle) + jar.back * sin(angle)) * r;
        const float3 color = lerp(g_Frame.tintAndScale.rgb, HashToUnit3(PcgHash(h ^ 0x51ED270Bu)) * 0.6 + 0.4, 0.5);
        DrawPoint(p, color, g_Frame.vacuumParams.z * 0.12, h);
    }
    else if (i < POINT_JAR_POINTS + POINT_JAR_OUTLINE)
    {
        const uint k = i - POINT_JAR_POINTS;
        float3 p;
        if (k < 768) // top and bottom rims
        {
            const float angle = float(k % 384) / 384.0 * 6.2831853;
            p = jar.bottom + jar.axis * (k < 384 ? jar.height : 0.0) + (jar.right * cos(angle) + jar.back * sin(angle)) * jar.radius;
        }
        else // four side edges
        {
            const uint e = (k - 768) / 64;
            const float angle = float(e) * 1.5707963 + 0.7853982;
            p = jar.bottom + jar.axis * (float((k - 768) % 64) / 63.0 * jar.height) + (jar.right * cos(angle) + jar.back * sin(angle)) * jar.radius;
        }
        DrawPoint(p, float3(0.7, 0.85, 1.0), g_Frame.vacuumParams.z * 0.05, h);
    }
}
