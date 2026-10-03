// SHATTER: diamond-dust point clouds (PLAN section 4, milestone M1).
//   Generate(): CPU density grid per cloud -> GPU generation of 4-byte points in batches of 4096.
//   Render():   per cloud: batch cull + LOD -> additive compute raster at display resolution; then one composite
//               into the upscaled HDR scene color (before bloom and tone mapping).
#pragma once

#include <array>
#include <memory>
#include <string>
#include <vector>

#include <nvrhi/nvrhi.h>
#include <json/json.h>
#include <donut/core/math/math.h>
#include <donut/engine/BindingCache.h>
#include <donut/engine/ShaderFactory.h>

#include "Shaders/Points/PointShared.h"

namespace shatter
{
    class GpuProfiler;

    enum class PointAtomicMode : int { Int64 = 0, Fp16x4 = 1 };

    // UI + command line state. Changes to the "generation" group take effect on the next regenerate.
    struct PointSettings
    {
        bool  enabled = true;

        // generation (press Regenerate)
        int   totalMillions = 1000;         // points across all clouds
        int   cloudCount = 4;               // raised automatically so no cloud exceeds kMaxPointsPerCloud
        float cloudRadius = 0.75f;          // m
        float cloudDistance = 6.0f;         // m in front of the anchor camera
        int   gridLog2 = 7;                 // density grid resolution (1 << gridLog2)^3
        float warp = 0.6f;
        float noiseFrequency = 1.5f;
        float jitterCells = 1.0f;           // B-spline scatter kernel scale (cells)

        // rendering (live)
        float brightness = 1.0f;            // average scene radiance of a cloud seen face-on
        dm::float3 tint = dm::float3(0.85f, 0.92f, 1.0f);
        PointAtomicMode atomicMode = PointAtomicMode::Int64;
        bool  lod = true;
        float maxPointsPerPixel = 16.f;
        bool  waveAggregation = true;
        float aggregateMaxPixels = 24.f;
        float depthBias = 0.002f;           // relative linear depth tolerance against the render-res scene depth
        float minDistance = 0.05f;          // m, clamps the 1/d^2 falloff

        // requests
        bool  regenerate = false;
        bool  reanchor = false;             // regenerate around the current camera

        // stats (filled by PointCloudSystem, read by UI and bench JSON)
        uint64_t statTotalPoints = 0;
        uint32_t statClouds = 0;
        uint64_t statRenderedPoints = 0;    // points sent to the raster, a few frames late
        uint64_t statVisibleBatches = 0;
        double   statRenderedPointsAvg = 0; // mean over the last kStatWindow frames
        uint64_t statGpuBytes = 0;
        float    statGenerateCpuMs = 0.f;
        float    statGenerateGpuMs = 0.f;
    };

    struct PointRenderParams
    {
        nvrhi::ITexture* sceneColor = nullptr;      // display resolution RGBA16F with UAV; points are added in place
        nvrhi::ITexture* sceneDepth = nullptr;      // render resolution R32F reverse-Z NDC depth (0 = sky)
        dm::float4x4 worldToClip;                   // no jitter
        dm::float3 cameraPos;
        float zNear = 0.001f;
        float projScaleY = 1.f;                     // projection[1][1] = 1 / tan(fovY / 2)
        dm::uint2 displaySize;
        dm::uint2 renderSize;
        float exposure = 1.f;                       // scalar exposure, sets the fixed-point scale
        uint32_t frameIndex = 0;
    };

    class PointCloudSystem
    {
    public:
        static constexpr uint32_t kMaxPointsPerCloud = 512u * 1024u * 1024u; // 2 GB of positions per buffer
        static constexpr int kStatWindow = 256;

        PointCloudSystem(nvrhi::IDevice* device, std::shared_ptr<donut::engine::ShaderFactory> shaderFactory);

        bool HasClouds() const { return !m_clouds.empty(); }

        // (Re)generates every cloud in a row in front of the anchor. Records GPU work into the open command list.
        // The CPU density grids take a moment; this is load-time work, not per frame.
        void Generate(nvrhi::ICommandList* commandList, PointSettings& settings, const dm::float3& anchorPos, const dm::float3& anchorDir);

        void Render(nvrhi::ICommandList* commandList, const PointRenderParams& params, PointSettings& settings, GpuProfiler* profiler);

        static Json::Value BenchJson(const PointSettings& settings);

    private:
        struct Cloud
        {
            uint32_t pointCount = 0;
            uint32_t batchCount = 0;
            uint32_t seed = 0;
            float    pointScale = 0.f;              // per-point intensity before 1/d^2 and 1/pixel solid angle
            nvrhi::BufferHandle positions;          // uint per point
            nvrhi::BufferHandle batches;            // PointBatch per batch
            nvrhi::BufferHandle collected;          // 1 bit per point
            nvrhi::BufferHandle visible;            // uint2 per batch
            nvrhi::BufferHandle args;               // 4 uints: dispatch args + visible count
            nvrhi::BufferHandle count;              // 1 uint: visible count for the raster
        };

        void CreatePipelines();
        void EnsureAccumulation(nvrhi::ICommandList* commandList, PointAtomicMode mode, dm::uint2 displaySize, dm::uint2 renderSize);
        void ReadStats(PointSettings& settings);

        nvrhi::IDevice* m_device;
        std::shared_ptr<donut::engine::ShaderFactory> m_shaderFactory;
        donut::engine::BindingCache m_bindingCache;

        nvrhi::BindingLayoutHandle m_generateLayout;
        nvrhi::BindingLayoutHandle m_cullLayout;
        nvrhi::BindingLayoutHandle m_rasterLayout[2];     // indexed by PointAtomicMode
        nvrhi::BindingLayoutHandle m_compositeLayout[2];
        nvrhi::ComputePipelineHandle m_generatePso;
        nvrhi::ComputePipelineHandle m_cullPso;
        nvrhi::ComputePipelineHandle m_finalizePso;
        nvrhi::ComputePipelineHandle m_rasterPso[2];
        nvrhi::ComputePipelineHandle m_compositePso[2];

        nvrhi::BufferHandle m_generateConstants;
        nvrhi::BufferHandle m_frameConstants;
        nvrhi::BufferHandle m_stats;                      // 2 x uint64
        static constexpr int kReadbackRing = 4;
        std::array<nvrhi::BufferHandle, kReadbackRing> m_statsReadback;
        std::array<bool, kReadbackRing> m_readbackPending = {};
        int m_readbackSlot = 0;

        nvrhi::BufferHandle  m_accumInt64;                // uint64 per display pixel
        nvrhi::TextureHandle m_accumFp16;                 // RGBA16F, display size
        PointAtomicMode m_accumMode = PointAtomicMode::Int64;
        dm::uint2 m_accumSize = dm::uint2(0u);
        dm::uint2 m_renderSize = dm::uint2(0u);

        nvrhi::TimerQueryHandle m_generateTimer;
        bool m_generateTimerPending = false;

        std::vector<Cloud> m_clouds;
        bool m_hasAnchor = false;
        dm::float3 m_anchorPos = dm::float3(0.f);
        dm::float3 m_anchorDir = dm::float3(0.f, 0.f, -1.f);

        std::vector<uint64_t> m_renderedHistory;
        size_t m_renderedHistoryNext = 0;
    };
}
