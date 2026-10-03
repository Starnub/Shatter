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
        // soft falloff in distance and angle: no hard edge, so the crater has no cookie-cutter wall
        const float radial = 1.0 - dist / radius;
        const float w = radial * radial * radial * smoothstep(cosCone, 1.0, dot(d, fwd) / max(dist, 1e-5));
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
        q.position = DriftPoint(p, h, g_Frame.motionParams.x, g_Frame.motionParams.y); // exactly where the raster drew it
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

// Soft disc of a given world radius: projected size grows as it approaches (the depth cue single pixels lack).
// The weights are normalized, so a disc carries exactly the energy of a single-pixel point.
void DrawSplat(float3 p, float3 color, float intensity, uint seed, float worldRadius)
{
    const float4 clip = mul(float4(p, 1.0), g_Frame.worldToClip);
    if (clip.w <= g_Frame.cameraPosAndNear.w)
        return;
    const float r = min(worldRadius * g_Frame.motionParams.z / clip.w, 4.0);
    if (r < 0.7)
    {
        DrawPoint(p, color, intensity, seed);
        return;
    }
    const float2 pixel = (clip.xy / clip.w * float2(0.5, -0.5) + 0.5) * g_Frame.displaySizeAndInv.xy;
    const float3 d = p - g_Frame.cameraPosAndNear.xyz;
    const float minDistance2 = g_Frame.renderScaleAndBias.w * g_Frame.renderScaleAndBias.w;
    const float3 units = color * (intensity / max(dot(d, d), minDistance2));
    const int R = int(ceil(r));
    const float invR2 = 1.0 / (r * r);
    float sum = 0.0;
    for (int y = -R; y <= R; y++)
        for (int x = -R; x <= R; x++)
        {
            const float2 o = floor(pixel) + float2(x, y) + 0.5 - pixel;
            sum += saturate(1.0 - dot(o, o) * invR2);
        }
    const float dither = HashToUnit(PcgHash(seed ^ (g_Frame.frameIndex * 0x9E3779B9u)));
    for (int y2 = -R; y2 <= R; y2++)
        for (int x2 = -R; x2 <= R; x2++)
        {
            const float2 o = floor(pixel) + float2(x2, y2) + 0.5 - pixel;
            const float w = saturate(1.0 - dot(o, o) * invR2) / sum;
            const int2 ip = int2(floor(pixel)) + int2(x2, y2);
            if (w <= 0.0 || any(ip < 0) || any(ip >= int2(g_Frame.sizes.xy)))
                continue;
            const uint3 c = min(uint3(units * w + dither), POINT_FIXED_POINT_MAX.xxx);
            if (all(c == 0u))
                continue;
            InterlockedAdd(u_Accum[ip.y * g_Frame.sizes.x + ip.x], (uint64_t)c.x | ((uint64_t)c.y << 21) | ((uint64_t)c.z << 42));
        }
}

float JarFill() { return saturate(float(u_Vacuum[0]) / max(g_Frame.vacuumParams.w, 1.0)); }

[numthreads(POINT_PARTICLE_GROUP, 1, 1)]
void main_particles(uint3 dtid : SV_DispatchThreadID)
{
    PointParticle q = u_Particles[dtid.x];
    if (!(q.age >= 0.0))
        return; // dead (cleared to -1.0f)

    const float dt = g_Frame.vacuumParams.y;
    const float3 fwd = g_Frame.vacuumDirAndCos.xyz;
    const Jar jar = GetJar();

    // where the particle is relative to the jar, and its resting spot on the current fill surface
    const float3 rel = q.position - jar.bottom;
    const float along = dot(rel, jar.axis);
    const float radial = length(rel - jar.axis * along);
    const float a = HashToUnit(PcgHash(q.seed ^ 0x9B05688Cu)) * 6.2831853;
    const float rr = sqrt(HashToUnit(PcgHash(q.seed ^ 0x1F83D9ABu))) * jar.radius * 0.85;
    const float3 settle = jar.bottom + jar.axis * (JarFill() * jar.height * 0.97 + 0.002) + (jar.right * cos(a) + jar.back * sin(a)) * rr;

    const bool inJar = radial < jar.radius * 0.9 && along < jar.height + 0.015;
    const bool overMouth = radial < jar.radius * 0.7 && along >= jar.height;
    const float3 target = (inJar || overMouth) ? settle : jar.bottom + jar.axis * (jar.height + 0.03);

    // sink flow toward the target: slow far away, fast close in; inside the jar the particles drift down gently
    const float3 to = target - q.position;
    const float dist = length(to);
    const float3 dir = to / max(dist, 1e-4);
    float speed = clamp(0.04 / max(dist * dist, 1e-4), 0.08, 2.5);
    if (inJar)
        speed = min(speed, 0.25);
    const float spin = HashToUnit(PcgHash(q.seed ^ 0x7A3D9E21u)) * 2.0 - 1.0;
    const float3 desired = dir * speed + cross(fwd, dir) * (inJar ? 0.0 : spin * 0.15 * speed);
    q.velocity = lerp(q.velocity, desired, 1.0 - exp(-(inJar ? 8.0 : 4.0) * dt));

    q.position += q.velocity * dt;
    q.age += dt;
    if ((inJar && dist < max(0.004, length(q.velocity) * dt * 1.5)) || q.age > 4.0)
    {
        q.age = -1.0; // settled: the jar contents take over
        u_Particles[dtid.x] = q;
        return;
    }
    u_Particles[dtid.x] = q;

    // exactly the brightness the point had in the cloud (PointRaster), spread over a disc that grows as it nears
    const float intensity = g_Frame.tintAndScale.w * PointBrightness(q.seed) * g_Frame.fixedScale;
    DrawSplat(q.position, g_Frame.tintAndScale.rgb, intensity, q.seed, g_Frame.motionParams.w);
}

// Jar contents fill from the bottom with the collected total; sparse brighter points draw the glass.
[numthreads(POINT_PARTICLE_GROUP, 1, 1)]
void main_jar(uint3 dtid : SV_DispatchThreadID)
{
    const Jar jar = GetJar();
    const uint i = dtid.x;
    const uint h = PcgHash(i ^ 0x6A09E667u);
    const float t = g_Frame.motionParams.x;
    if (i < POINT_JAR_POINTS)
    {
        const float fill = JarFill();
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
        const float3 glass = float3(0.7, 0.85, 1.0);
        float3 p;
        float strength;
        if (k < 2048) // top and bottom rims
        {
            const float angle = float(k % 1024) / 1024.0 * 6.2831853;
            p = jar.bottom + jar.axis * (k < 1024 ? jar.height : 0.0) + (jar.right * cos(angle) + jar.back * sin(angle)) * jar.radius;
            strength = 0.5;
        }
        else if (k < 4096) // eight side edges
        {
            const uint e = (k - 2048) / 256;
            const float angle = float(e) * 0.7853982 + 0.3926991;
            p = jar.bottom + jar.axis * (float((k - 2048) % 256) / 255.0 * jar.height) + (jar.right * cos(angle) + jar.back * sin(angle)) * jar.radius;
            strength = 0.25;
        }
        else // a faint random scatter over the glass surface
        {
            const float angle = HashToUnit(PcgHash(h ^ 0xA54FF53Au)) * 6.2831853;
            p = jar.bottom + jar.axis * (HashToUnit(PcgHash(h ^ 0x510E527Fu)) * jar.height) + (jar.right * cos(angle) + jar.back * sin(angle)) * jar.radius;
            strength = 0.12;
        }
        DrawSplat(p, glass, g_Frame.vacuumParams.z * strength, h, 0.0004);
    }
}
