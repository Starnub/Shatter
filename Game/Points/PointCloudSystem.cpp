#include "PointCloudSystem.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#include <donut/core/log.h>

#include "Automation/GpuProfiler.h"
#include "CloudDensity.h"

using namespace donut::math;

namespace shatter
{
    namespace
    {
        constexpr float kPi = 3.14159265358979f;
        constexpr float kFixedUnitsPerExposedUnit = 2048.f; // int64 mode: 1 unit = 1/2048 of exposed scene value 1.0

        nvrhi::BufferHandle CreateStructuredBuffer(nvrhi::IDevice* device, uint64_t byteSize, uint32_t stride, const char* name, bool indirectArgs = false)
        {
            nvrhi::BufferDesc d;
            d.byteSize = std::max<uint64_t>(byteSize, stride);
            d.structStride = stride;
            d.canHaveUAVs = true;
            d.isDrawIndirectArgs = indirectArgs;
            d.debugName = name;
            d.initialState = nvrhi::ResourceStates::ShaderResource;
            d.keepInitialState = true;
            return device->createBuffer(d);
        }

        uint32_t DispatchRows(uint32_t groups) { return (groups + POINT_DISPATCH_ROW - 1) / POINT_DISPATCH_ROW; }
        uint32_t DispatchCols(uint32_t groups) { return std::min<uint32_t>(groups, POINT_DISPATCH_ROW); }
    }

    PointCloudSystem::PointCloudSystem(nvrhi::IDevice* device, std::shared_ptr<donut::engine::ShaderFactory> shaderFactory)
        : m_device(device)
        , m_shaderFactory(std::move(shaderFactory))
        , m_bindingCache(device)
    {
        CreatePipelines();

        nvrhi::BufferDesc cb;
        cb.isConstantBuffer = true;
        cb.isVolatile = true;
        cb.maxVersions = 256; // two writes per cloud per frame, several frames in flight
        cb.byteSize = sizeof(PointGenerateConstants);
        cb.debugName = "PointGenerateConstants";
        m_generateConstants = m_device->createBuffer(cb);
        cb.byteSize = sizeof(PointFrameConstants);
        cb.debugName = "PointFrameConstants";
        m_frameConstants = m_device->createBuffer(cb);

        m_stats = CreateStructuredBuffer(m_device, 2 * sizeof(uint64_t), sizeof(uint64_t), "PointStats");
        for (nvrhi::BufferHandle& rb : m_statsReadback)
        {
            nvrhi::BufferDesc d;
            d.byteSize = 2 * sizeof(uint64_t);
            d.cpuAccess = nvrhi::CpuAccessMode::Read;
            d.debugName = "PointStatsReadback";
            d.initialState = nvrhi::ResourceStates::CopyDest;
            d.keepInitialState = true;
            rb = m_device->createBuffer(d);
        }

        m_generateTimer = m_device->createTimerQuery();
        m_renderedHistory.assign(kStatWindow, 0);
    }

    void PointCloudSystem::CreatePipelines()
    {
        using namespace nvrhi;
        const char* generatePath = "shatter/Shaders/Points/PointGenerate.hlsl";
        const char* cullPath = "shatter/Shaders/Points/PointCull.hlsl";
        const char* rasterPath = "shatter/Shaders/Points/PointRaster.hlsl";
        const char* compositePath = "shatter/Shaders/Points/PointComposite.hlsl";

        {
            BindingLayoutDesc d;
            d.visibility = ShaderType::Compute;
            d.bindings = {
                BindingLayoutItem::VolatileConstantBuffer(0),
                BindingLayoutItem::StructuredBuffer_SRV(0),
                BindingLayoutItem::StructuredBuffer_UAV(0),
                BindingLayoutItem::StructuredBuffer_UAV(1),
                BindingLayoutItem::StructuredBuffer_UAV(2)
            };
            m_generateLayout = m_device->createBindingLayout(d);
            ShaderHandle cs = m_shaderFactory->CreateShader(generatePath, "main", nullptr, ShaderType::Compute);
            m_generatePso = m_device->createComputePipeline(ComputePipelineDesc().setComputeShader(cs).addBindingLayout(m_generateLayout));
        }
        {
            BindingLayoutDesc d;
            d.visibility = ShaderType::Compute;
            d.bindings = {
                BindingLayoutItem::VolatileConstantBuffer(0),
                BindingLayoutItem::StructuredBuffer_SRV(0),
                BindingLayoutItem::StructuredBuffer_UAV(0),
                BindingLayoutItem::StructuredBuffer_UAV(1),
                BindingLayoutItem::StructuredBuffer_UAV(2),
                BindingLayoutItem::StructuredBuffer_UAV(3)
            };
            m_cullLayout = m_device->createBindingLayout(d);
            ShaderHandle cull = m_shaderFactory->CreateShader(cullPath, "main_cull", nullptr, ShaderType::Compute);
            ShaderHandle finalize = m_shaderFactory->CreateShader(cullPath, "main_finalize", nullptr, ShaderType::Compute);
            m_cullPso = m_device->createComputePipeline(ComputePipelineDesc().setComputeShader(cull).addBindingLayout(m_cullLayout));
            m_finalizePso = m_device->createComputePipeline(ComputePipelineDesc().setComputeShader(finalize).addBindingLayout(m_cullLayout));
        }
        for (int mode = 0; mode < 2; mode++)
        {
            const bool fp16 = (mode == int(PointAtomicMode::Fp16x4));
            const std::vector<donut::engine::ShaderMacro> defines = { { "ATOMIC_FP16X4", fp16 ? "1" : "0" } };

            BindingLayoutDesc raster;
            raster.visibility = ShaderType::Compute;
            raster.bindings = {
                BindingLayoutItem::VolatileConstantBuffer(0),
                BindingLayoutItem::StructuredBuffer_SRV(0),
                BindingLayoutItem::StructuredBuffer_SRV(1),
                BindingLayoutItem::StructuredBuffer_SRV(2),
                BindingLayoutItem::StructuredBuffer_SRV(3),
                BindingLayoutItem::StructuredBuffer_SRV(4),
                BindingLayoutItem::Texture_SRV(5),
                fp16 ? BindingLayoutItem::Texture_UAV(0) : BindingLayoutItem::StructuredBuffer_UAV(0)
            };
            if (fp16)
                raster.bindings.push_back(BindingLayoutItem::TypedBuffer_UAV(127)); // NVAPI extension slot (u127, space0)
            m_rasterLayout[mode] = m_device->createBindingLayout(raster);

            ShaderDesc rasterDesc;
            rasterDesc.shaderType = ShaderType::Compute;
            if (fp16)
                rasterDesc.hlslExtensionsUAV = 127;
            ShaderHandle rasterCs = m_shaderFactory->CreateShader(rasterPath, "main", &defines, rasterDesc);
            m_rasterPso[mode] = m_device->createComputePipeline(ComputePipelineDesc().setComputeShader(rasterCs).addBindingLayout(m_rasterLayout[mode]));

            BindingLayoutDesc composite;
            composite.visibility = ShaderType::Compute;
            composite.bindings = {
                BindingLayoutItem::VolatileConstantBuffer(0),
                fp16 ? BindingLayoutItem::Texture_UAV(0) : BindingLayoutItem::StructuredBuffer_UAV(0),
                BindingLayoutItem::Texture_UAV(1)
            };
            m_compositeLayout[mode] = m_device->createBindingLayout(composite);
            ShaderHandle compositeCs = m_shaderFactory->CreateShader(compositePath, "main", &defines, ShaderType::Compute);
            m_compositePso[mode] = m_device->createComputePipeline(ComputePipelineDesc().setComputeShader(compositeCs).addBindingLayout(m_compositeLayout[mode]));
        }

        if (!m_generatePso || !m_cullPso || !m_finalizePso || !m_rasterPso[0] || !m_rasterPso[1] || !m_compositePso[0] || !m_compositePso[1])
            donut::log::error("Shatter points: failed to create one or more compute pipelines (see messages above)");
    }

    void PointCloudSystem::Generate(nvrhi::ICommandList* commandList, PointSettings& settings, const float3& anchorPos, const float3& anchorDir)
    {
        if (settings.reanchor || !m_hasAnchor)
        {
            m_anchorPos = anchorPos;
            m_anchorDir = anchorDir;
            m_hasAnchor = true;
        }
        settings.regenerate = false;
        settings.reanchor = false;

        m_clouds.clear();
        m_bindingCache.Clear();
        if (!m_generatePso)
            return;

        const uint64_t totalPoints = uint64_t(std::max(1, settings.totalMillions)) * 1000000ull;
        uint32_t cloudCount = uint32_t(std::max(1, settings.cloudCount));
        while ((totalPoints + cloudCount - 1) / cloudCount > kMaxPointsPerCloud)
            cloudCount++;
        settings.cloudCount = int(cloudCount);

        // a row of clouds across the view, at the anchor's height
        float3 forward = float3(m_anchorDir.x, 0.f, m_anchorDir.z);
        forward = (length(forward) > 1e-3f) ? normalize(forward) : float3(0.f, 0.f, -1.f);
        const float3 right = normalize(cross(forward, float3(0.f, 1.f, 0.f)));
        const float spacing = 2.2f * settings.cloudRadius;

        const auto cpuStart = std::chrono::steady_clock::now();
        double cpuGridMs = 0.0;
        uint64_t gpuBytes = 0;

        commandList->beginMarker("Shatter Points Generate");
        const bool timed = !m_generateTimerPending; // a query still in flight can't be restarted
        if (timed)
            commandList->beginTimerQuery(m_generateTimer);

        uint64_t assigned = 0;
        for (uint32_t i = 0; i < cloudCount; i++)
        {
            Cloud cloud;
            cloud.pointCount = uint32_t((i + 1 == cloudCount) ? (totalPoints - assigned) : (totalPoints / cloudCount));
            assigned += cloud.pointCount;
            cloud.batchCount = (cloud.pointCount + POINT_BATCH_SIZE - 1) / POINT_BATCH_SIZE;
            cloud.seed = 0x5EED0000u + i * 7919u;
            cloud.pointScale = kPi * settings.cloudRadius * settings.cloudRadius / float(cloud.pointCount);

            CloudShape shape;
            shape.center = m_anchorPos + forward * settings.cloudDistance + right * ((float(i) - 0.5f * float(cloudCount - 1)) * spacing);
            shape.radius = settings.cloudRadius;
            shape.warp = settings.warp;
            shape.noiseFrequency = settings.noiseFrequency;
            shape.seed = cloud.seed;

            const auto gridStart = std::chrono::steady_clock::now();
            const CloudDensityGrid grid = BuildCloudDensityGrid(shape, uint32_t(settings.gridLog2), cloud.pointCount);
            cpuGridMs += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - gridStart).count();

            const uint32_t maskWords = cloud.batchCount * POINT_MASK_WORDS_PER_BATCH;
            cloud.positions = CreateStructuredBuffer(m_device, uint64_t(cloud.pointCount) * 4, 4, "PointPositions");
            cloud.batches = CreateStructuredBuffer(m_device, uint64_t(cloud.batchCount) * sizeof(PointBatch), sizeof(PointBatch), "PointBatches");
            cloud.collected = CreateStructuredBuffer(m_device, uint64_t(maskWords) * 4, 4, "PointCollected");
            cloud.visible = CreateStructuredBuffer(m_device, uint64_t(cloud.batchCount) * 8, 8, "PointVisible");
            cloud.args = CreateStructuredBuffer(m_device, 16, 4, "PointArgs", true);
            cloud.count = CreateStructuredBuffer(m_device, 4, 4, "PointVisibleCount");
            if (!cloud.positions || !cloud.batches || !cloud.collected || !cloud.visible || !cloud.args || !cloud.count)
            {
                donut::log::error("Shatter points: buffer allocation failed for cloud %u (%u points)", i, cloud.pointCount);
                break;
            }
            gpuBytes += uint64_t(cloud.pointCount) * 4 + uint64_t(cloud.batchCount) * (sizeof(PointBatch) + 8) + uint64_t(maskWords) * 4;

            nvrhi::BufferHandle offsets = CreateStructuredBuffer(m_device, grid.cellOffsets.size() * 4, 4, "PointCellOffsets");
            commandList->writeBuffer(offsets, grid.cellOffsets.data(), grid.cellOffsets.size() * 4);

            PointGenerateConstants gc = {};
            gc.gridMinAndCellSize = float4(grid.gridMin, grid.cellSize);
            gc.gridLog2 = grid.gridLog2;
            gc.cellCount = uint32_t(grid.cellOffsets.size() - 1);
            gc.pointCount = cloud.pointCount;
            gc.batchCount = cloud.batchCount;
            gc.seed = cloud.seed;
            gc.jitterCells = settings.jitterCells;
            commandList->writeBuffer(m_generateConstants, &gc, sizeof(gc));

            // one-off binding set: not cached, so the temporary offsets buffer is released after this frame
            nvrhi::BindingSetDesc setDesc;
            setDesc.bindings = {
                nvrhi::BindingSetItem::ConstantBuffer(0, m_generateConstants),
                nvrhi::BindingSetItem::StructuredBuffer_SRV(0, offsets),
                nvrhi::BindingSetItem::StructuredBuffer_UAV(0, cloud.positions),
                nvrhi::BindingSetItem::StructuredBuffer_UAV(1, cloud.batches),
                nvrhi::BindingSetItem::StructuredBuffer_UAV(2, cloud.collected)
            };
            nvrhi::BindingSetHandle set = m_device->createBindingSet(setDesc, m_generateLayout);

            nvrhi::ComputeState state;
            state.pipeline = m_generatePso;
            state.bindings = { set };
            commandList->setComputeState(state);
            commandList->dispatch(DispatchCols(cloud.batchCount), DispatchRows(cloud.batchCount), 1);

            m_clouds.push_back(std::move(cloud));
        }

        if (timed)
        {
            commandList->endTimerQuery(m_generateTimer);
            m_generateTimerPending = true;
        }
        commandList->endMarker();

        settings.statClouds = uint32_t(m_clouds.size());
        settings.statTotalPoints = 0;
        for (const Cloud& c : m_clouds)
            settings.statTotalPoints += c.pointCount;
        settings.statGpuBytes = gpuBytes;
        settings.statGenerateCpuMs = float(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - cpuStart).count());
        settings.statGenerateGpuMs = 0.f;
        std::fill(m_renderedHistory.begin(), m_renderedHistory.end(), 0ull);

        donut::log::info("Shatter points: %u clouds, %llu points, %.1f MB GPU, density grids %.0f ms (CPU)",
            settings.statClouds, (unsigned long long)settings.statTotalPoints, double(gpuBytes) / (1024.0 * 1024.0), cpuGridMs);
    }

    void PointCloudSystem::EnsureAccumulation(nvrhi::ICommandList* commandList, PointAtomicMode mode, uint2 displaySize, uint2 renderSize)
    {
        if (any(renderSize != m_renderSize))
        {
            m_renderSize = renderSize;
            m_bindingCache.Clear(); // the scene depth texture was re-created
        }
        if (mode == m_accumMode && all(displaySize == m_accumSize) && (m_accumInt64 || m_accumFp16))
            return;

        m_bindingCache.Clear();
        m_accumInt64 = nullptr;
        m_accumFp16 = nullptr;
        m_accumMode = mode;
        m_accumSize = displaySize;

        if (mode == PointAtomicMode::Int64)
        {
            m_accumInt64 = CreateStructuredBuffer(m_device, uint64_t(displaySize.x) * displaySize.y * 8, 8, "PointAccumInt64");
            commandList->clearBufferUInt(m_accumInt64, 0);
        }
        else
        {
            nvrhi::TextureDesc d;
            d.width = displaySize.x;
            d.height = displaySize.y;
            d.format = nvrhi::Format::RGBA16_FLOAT;
            d.isUAV = true;
            d.debugName = "PointAccumFp16";
            d.initialState = nvrhi::ResourceStates::UnorderedAccess;
            d.keepInitialState = true;
            m_accumFp16 = m_device->createTexture(d);
            commandList->clearTextureFloat(m_accumFp16, nvrhi::AllSubresources, nvrhi::Color(0.f));
        }
    }

    void PointCloudSystem::ReadStats(PointSettings& settings)
    {
        // the slot about to be overwritten was written kReadbackRing frames ago
        const int slot = m_readbackSlot;
        if (!m_readbackPending[slot])
            return;
        m_readbackPending[slot] = false;

        const uint64_t* data = static_cast<const uint64_t*>(m_device->mapBuffer(m_statsReadback[slot], nvrhi::CpuAccessMode::Read));
        if (!data)
            return;
        settings.statRenderedPoints = data[0];
        settings.statVisibleBatches = data[1];
        m_device->unmapBuffer(m_statsReadback[slot]);

        m_renderedHistory[m_renderedHistoryNext] = settings.statRenderedPoints;
        m_renderedHistoryNext = (m_renderedHistoryNext + 1) % m_renderedHistory.size();
        double sum = 0.0;
        for (uint64_t v : m_renderedHistory)
            sum += double(v);
        settings.statRenderedPointsAvg = sum / double(m_renderedHistory.size());
    }

    void PointCloudSystem::Render(nvrhi::ICommandList* commandList, const PointRenderParams& params, PointSettings& settings, GpuProfiler* profiler)
    {
        if (m_generateTimerPending && m_device->pollTimerQuery(m_generateTimer))
        {
            settings.statGenerateGpuMs = m_device->getTimerQueryTime(m_generateTimer) * 1000.f;
            m_generateTimerPending = false;
        }
        ReadStats(settings);

        if (m_clouds.empty() || !params.sceneColor || !params.sceneDepth)
            return;

        const int mode = int(settings.atomicMode);
        if (!m_rasterPso[mode] || !m_compositePso[mode] || !m_cullPso || !m_finalizePso)
            return;

        EnsureAccumulation(commandList, settings.atomicMode, params.displaySize, params.renderSize);
        auto accumUav = [&](uint32_t slot) -> nvrhi::BindingSetItem
        {
            return (settings.atomicMode == PointAtomicMode::Int64)
                ? nvrhi::BindingSetItem::StructuredBuffer_UAV(slot, m_accumInt64)
                : nvrhi::BindingSetItem::Texture_UAV(slot, m_accumFp16);
        };

        // radians per pixel at the image center -> 1 / pixel solid angle
        const float pixelAngle = 2.f / (params.projScaleY * float(params.displaySize.y));
        const float invPixelSolidAngle = 1.f / (pixelAngle * pixelAngle);
        const float fixedScale = kFixedUnitsPerExposedUnit * std::max(params.exposure, 1e-8f);

        PointFrameConstants fc = {};
        fc.worldToClip = params.worldToClip;
        fc.cameraPosAndNear = float4(params.cameraPos, params.zNear);
        fc.displaySizeAndInv = float4(float(params.displaySize.x), float(params.displaySize.y), 1.f / float(params.displaySize.x), 1.f / float(params.displaySize.y));
        fc.renderScaleAndBias = float4(float(params.renderSize.x) / float(params.displaySize.x), float(params.renderSize.y) / float(params.displaySize.y),
                                       settings.depthBias, settings.minDistance);
        fc.sizes = uint4(params.displaySize.x, params.displaySize.y, params.renderSize.x, params.renderSize.y);
        fc.fixedScale = fixedScale;
        fc.invFixedScale = 1.f / fixedScale;
        fc.maxPointsPerPixel = settings.maxPointsPerPixel;
        fc.aggregateMaxPixels = settings.waveAggregation ? settings.aggregateMaxPixels : 0.f;
        fc.lodEnabled = settings.lod ? 1u : 0u;
        fc.frameIndex = params.frameIndex;

        auto cloudConstants = [&](const Cloud& c)
        {
            fc.tintAndScale = float4(settings.tint, settings.brightness * c.pointScale * invPixelSolidAngle);
            fc.batchCount = c.batchCount;
            fc.cloudSeed = c.seed;
            commandList->writeBuffer(m_frameConstants, &fc, sizeof(fc));
        };

        const uint64_t zeros[2] = { 0, 0 };
        commandList->writeBuffer(m_stats, zeros, sizeof(zeros));

        commandList->beginMarker("Shatter Points");

        // 1. cull + LOD for every cloud. Stats are only touched by atomics, so no UAV barriers between clouds.
        if (profiler) profiler->Begin(commandList, "Points_Cull");
        commandList->setEnableUavBarriersForBuffer(m_stats, false);
        for (const Cloud& c : m_clouds)
        {
            commandList->writeBuffer(c.args, zeros, 16);
            cloudConstants(c);

            nvrhi::BindingSetDesc d;
            d.bindings = {
                nvrhi::BindingSetItem::ConstantBuffer(0, m_frameConstants),
                nvrhi::BindingSetItem::StructuredBuffer_SRV(0, c.batches),
                nvrhi::BindingSetItem::StructuredBuffer_UAV(0, c.visible),
                nvrhi::BindingSetItem::StructuredBuffer_UAV(1, c.args),
                nvrhi::BindingSetItem::StructuredBuffer_UAV(2, m_stats),
                nvrhi::BindingSetItem::StructuredBuffer_UAV(3, c.count)
            };
            nvrhi::BindingSetHandle set = m_bindingCache.GetOrCreateBindingSet(d, m_cullLayout);

            nvrhi::ComputeState state;
            state.pipeline = m_cullPso;
            state.bindings = { set };
            commandList->setComputeState(state);
            commandList->dispatch((c.batchCount + POINT_CULL_GROUP_SIZE - 1) / POINT_CULL_GROUP_SIZE, 1, 1);

            state.pipeline = m_finalizePso;
            commandList->setComputeState(state);
            commandList->dispatch(1, 1, 1);
        }
        commandList->setEnableUavBarriersForBuffer(m_stats, true);
        if (profiler) profiler->End(commandList);

        // 2. raster. Clouds only add into the accumulation target with atomics, so no UAV barriers between them.
        if (profiler) profiler->Begin(commandList, "Points_Raster");
        if (settings.atomicMode == PointAtomicMode::Int64)
            commandList->setEnableUavBarriersForBuffer(m_accumInt64, false);
        else
            commandList->setEnableUavBarriersForTexture(m_accumFp16, false);
        for (const Cloud& c : m_clouds)
        {
            cloudConstants(c);

            nvrhi::BindingSetDesc d;
            d.bindings = {
                nvrhi::BindingSetItem::ConstantBuffer(0, m_frameConstants),
                nvrhi::BindingSetItem::StructuredBuffer_SRV(0, c.batches),
                nvrhi::BindingSetItem::StructuredBuffer_SRV(1, c.positions),
                nvrhi::BindingSetItem::StructuredBuffer_SRV(2, c.collected),
                nvrhi::BindingSetItem::StructuredBuffer_SRV(3, c.visible),
                nvrhi::BindingSetItem::StructuredBuffer_SRV(4, c.count),
                nvrhi::BindingSetItem::Texture_SRV(5, params.sceneDepth),
                accumUav(0)
            };
            if (settings.atomicMode == PointAtomicMode::Fp16x4)
                d.bindings.push_back(nvrhi::BindingSetItem::TypedBuffer_UAV(127, nullptr));
            nvrhi::BindingSetHandle set = m_bindingCache.GetOrCreateBindingSet(d, m_rasterLayout[mode]);

            nvrhi::ComputeState state;
            state.pipeline = m_rasterPso[mode];
            state.bindings = { set };
            state.indirectParams = c.args;
            commandList->setComputeState(state);
            commandList->dispatchIndirect(0);
        }
        if (settings.atomicMode == PointAtomicMode::Int64)
            commandList->setEnableUavBarriersForBuffer(m_accumInt64, true);
        else
            commandList->setEnableUavBarriersForTexture(m_accumFp16, true);
        if (profiler) profiler->End(commandList);

        // 3. composite into the scene color and clear the accumulation target
        if (profiler) profiler->Begin(commandList, "Points_Composite");
        {
            nvrhi::BindingSetDesc d;
            d.bindings = {
                nvrhi::BindingSetItem::ConstantBuffer(0, m_frameConstants),
                accumUav(0),
                nvrhi::BindingSetItem::Texture_UAV(1, params.sceneColor)
            };
            nvrhi::BindingSetHandle set = m_bindingCache.GetOrCreateBindingSet(d, m_compositeLayout[mode]);

            nvrhi::ComputeState state;
            state.pipeline = m_compositePso[mode];
            state.bindings = { set };
            commandList->setComputeState(state);
            commandList->dispatch((params.displaySize.x + POINT_COMPOSITE_TILE - 1) / POINT_COMPOSITE_TILE,
                                  (params.displaySize.y + POINT_COMPOSITE_TILE - 1) / POINT_COMPOSITE_TILE, 1);
        }
        if (profiler) profiler->End(commandList);

        commandList->endMarker();

        commandList->copyBuffer(m_statsReadback[m_readbackSlot], 0, m_stats, 0, sizeof(zeros));
        m_readbackPending[m_readbackSlot] = true;
        m_readbackSlot = (m_readbackSlot + 1) % kReadbackRing;
    }

    Json::Value PointCloudSystem::BenchJson(const PointSettings& s)
    {
        Json::Value j(Json::objectValue);
        j["enabled"] = s.enabled;
        j["clouds"] = s.statClouds;
        j["total_points"] = Json::UInt64(s.statTotalPoints);
        j["rendered_points_avg"] = s.statRenderedPointsAvg;
        j["rendered_points_last"] = Json::UInt64(s.statRenderedPoints);
        j["visible_batches_last"] = Json::UInt64(s.statVisibleBatches);
        j["gpu_mb"] = double(s.statGpuBytes) / (1024.0 * 1024.0);
        j["generate_cpu_ms"] = s.statGenerateCpuMs;
        j["generate_gpu_ms"] = s.statGenerateGpuMs;
        j["atomic_mode"] = (s.atomicMode == PointAtomicMode::Int64) ? "int64" : "fp16x4";
        j["lod"] = s.lod;
        j["max_points_per_pixel"] = s.maxPointsPerPixel;
        j["wave_aggregation"] = s.waveAggregation;
        j["aggregate_max_pixels"] = s.aggregateMaxPixels;
        j["grid_log2"] = s.gridLog2;
        j["cloud_radius_m"] = s.cloudRadius;
        j["cloud_distance_m"] = s.cloudDistance;
        return j;
    }
}
