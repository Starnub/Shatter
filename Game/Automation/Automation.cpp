#include "Automation.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>

#include <tinyexr.h>
#include <donut/core/log.h>
#include <donut/engine/TextureCache.h> // SaveTextureToFile

namespace fs = std::filesystem;

namespace shatter
{
    static fs::path RepoRoot()
    {
        wchar_t buf[MAX_PATH * 4] = {};
        GetModuleFileNameW(nullptr, buf, DWORD(std::size(buf)));
        return fs::path(buf).parent_path().parent_path(); // <repo>/bin/Rtxpt.exe -> <repo>
    }

    static fs::path PresetFile() { return RepoRoot() / "Game" / "camera_presets.json"; }

    static bool WriteJson(const fs::path& path, const Json::Value& value)
    {
        std::error_code ec;
        fs::create_directories(path.parent_path(), ec);
        Json::StreamWriterBuilder builder;
        builder["indentation"] = "  ";
        std::ofstream file(path);
        if (!file)
            return false;
        file << Json::writeString(builder, value) << "\n";
        return bool(file);
    }

    static Json::Value ReadJson(const fs::path& path)
    {
        Json::Value root;
        std::ifstream file(path);
        if (file)
        {
            Json::CharReaderBuilder builder;
            std::string errs;
            if (!Json::parseFromStream(builder, file, &root, &errs))
                donut::log::warning("Failed to parse %s: %s", path.string().c_str(), errs.c_str());
        }
        return root;
    }

    std::string Automation::LoadCameraPreset(const std::string& scene, const std::string& name)
    {
        const Json::Value root = ReadJson(PresetFile());
        for (const char* key : { scene.c_str(), "*" })
            if (root.isMember(key) && root[key].isMember(name))
                return root[key][name].asString();
        donut::log::error("Camera preset '%s' not found for scene '%s' in %s", name.c_str(), scene.c_str(), PresetFile().string().c_str());
        return "";
    }

    bool Automation::SaveCameraPreset(const std::string& scene, const std::string& name, const std::string& posDirUp)
    {
        Json::Value root = ReadJson(PresetFile());
        if (!root.isObject())
            root = Json::Value(Json::objectValue);
        root[scene][name] = posDirUp;
        return WriteJson(PresetFile(), root);
    }

    Json::Value Automation::QueryVram(nvrhi::IDevice* device)
    {
        Json::Value out(Json::objectValue);
        using Microsoft::WRL::ComPtr;

        auto* d3dDevice = static_cast<ID3D12Device*>(device->getNativeObject(nvrhi::ObjectTypes::D3D12_Device).pointer);
        if (!d3dDevice)
            return out;

        ComPtr<IDXGIFactory4> factory;
        ComPtr<IDXGIAdapter3> adapter;
        if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))) ||
            FAILED(factory->EnumAdapterByLuid(d3dDevice->GetAdapterLuid(), IID_PPV_ARGS(&adapter))))
            return out;

        DXGI_QUERY_VIDEO_MEMORY_INFO info = {};
        if (SUCCEEDED(adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info)))
        {
            out["process_used_mb"] = Json::Value::UInt64(info.CurrentUsage >> 20);
            out["process_budget_mb"] = Json::Value::UInt64(info.Budget >> 20);
        }
        DXGI_ADAPTER_DESC desc = {};
        if (SUCCEEDED(adapter->GetDesc(&desc)))
            out["dedicated_total_mb"] = Json::Value::UInt64(desc.DedicatedVideoMemory >> 20);
        return out;
    }

    void Automation::BeginFrame(bool sceneReady)
    {
        m_profiler.BeginFrame();

        const auto now = std::chrono::steady_clock::now();

        if (sceneReady)
            m_framesReady++;

        if (BenchRequested() && !m_benchDone && sceneReady)
        {
            if (m_framesReady == kBenchWarmupFrames)
            {
                m_benchRecording = true;
                m_benchStart = now;
                m_profiler.SetRecording(true);
                m_cpuFrameMs.clear();
            }
            else if (m_benchRecording)
            {
                m_cpuFrameMs.push_back(std::chrono::duration<double, std::milli>(now - m_lastFrame).count());
            }
        }
        m_lastFrame = now;
    }

    void Automation::RecordCapture(nvrhi::IDevice* device, nvrhi::ICommandList* commandList, nvrhi::ITexture* hdrSource, nvrhi::ITexture* sdrPreview)
    {
        (void)sdrPreview; // rendered by the caller before this call; PNG goes through SaveTextureToFile after execution
        const nvrhi::TextureDesc& desc = hdrSource->getDesc();
        m_hdrFormat = desc.format;
        m_hdrWidth = desc.width;
        m_hdrHeight = desc.height;
        m_hdrStaging = device->createStagingTexture(desc, nvrhi::CpuAccessMode::Read);
        commandList->copyTexture(m_hdrStaging, nvrhi::TextureSlice(), hdrSource, nvrhi::TextureSlice());
        m_screenshotPending = true;
    }

    static float HalfToFloat(uint16_t h)
    {
        const uint32_t sign = (h & 0x8000u) << 16;
        uint32_t exp = (h >> 10) & 0x1f;
        uint32_t mant = h & 0x3ff;
        uint32_t bits;
        if (exp == 0)
        {
            if (mant == 0) bits = sign;
            else
            {
                exp = 127 - 15 + 1;
                while (!(mant & 0x400)) { mant <<= 1; exp--; }
                bits = sign | (exp << 23) | ((mant & 0x3ff) << 13);
            }
        }
        else if (exp == 31) bits = sign | 0x7f800000u | (mant << 13);
        else bits = sign | ((exp + 127 - 15) << 23) | (mant << 13);
        float f;
        memcpy(&f, &bits, sizeof(f));
        return f;
    }

    bool Automation::WriteScreenshot(nvrhi::IDevice* device, donut::engine::CommonRenderPasses* commonPasses, nvrhi::ITexture* sdrPreview)
    {
        const fs::path png = m_options.screenshotPath;
        fs::path exr = png;
        exr += ".exr";
        std::error_code ec;
        fs::create_directories(png.parent_path(), ec);

        // PNG: the SDR preview target is RGBA8_UNORM holding sRGB-encoded GT7 output.
        bool ok = donut::engine::SaveTextureToFile(device, commonPasses, sdrPreview, nvrhi::ResourceStates::RenderTarget, png.string().c_str());
        if (!ok)
            donut::log::error("Failed to write %s", png.string().c_str());

        // EXR: scene-referred linear radiance, before exposure and tone mapping.
        if (m_hdrFormat != nvrhi::Format::RGBA16_FLOAT && m_hdrFormat != nvrhi::Format::RGBA32_FLOAT)
        {
            donut::log::error("EXR export: unsupported source format");
            return false;
        }
        size_t rowPitch = 0;
        const uint8_t* src = static_cast<const uint8_t*>(device->mapStagingTexture(m_hdrStaging, nvrhi::TextureSlice(), nvrhi::CpuAccessMode::Read, &rowPitch));
        if (!src)
            return false;

        std::vector<float> pixels(size_t(m_hdrWidth) * m_hdrHeight * 4);
        for (uint32_t y = 0; y < m_hdrHeight; y++)
        {
            const uint8_t* row = src + y * rowPitch;
            float* dst = &pixels[size_t(y) * m_hdrWidth * 4];
            if (m_hdrFormat == nvrhi::Format::RGBA16_FLOAT)
                for (uint32_t i = 0; i < m_hdrWidth * 4; i++)
                    dst[i] = HalfToFloat(reinterpret_cast<const uint16_t*>(row)[i]);
            else
                memcpy(dst, row, size_t(m_hdrWidth) * 4 * sizeof(float));
        }
        device->unmapStagingTexture(m_hdrStaging);

        const char* err = nullptr;
        if (SaveEXR(pixels.data(), int(m_hdrWidth), int(m_hdrHeight), 4, /*save_as_fp16*/ 1, exr.string().c_str(), &err) < 0)
        {
            donut::log::error("Failed to write %s: %s", exr.string().c_str(), err ? err : "unknown");
            FreeEXRErrorMessage(err);
            return false;
        }
        donut::log::info("Screenshot written: %s (+ .exr)", png.string().c_str());
        return ok;
    }

    void Automation::WriteBench(nvrhi::IDevice* device, const Json::Value& meta)
    {
        Json::Value root(Json::objectValue);
        root["camera"] = m_options.camera.empty() ? "default" : m_options.camera;
        root["bench_seconds"] = m_options.benchSeconds;
        root["warmup_frames"] = kBenchWarmupFrames;
        for (const auto& name : meta.getMemberNames())
            root[name] = meta[name];

        std::vector<double> ms = m_cpuFrameMs;
        Json::Value frames(Json::objectValue);
        frames["count"] = Json::Value::UInt64(ms.size());
        if (!ms.empty())
        {
            double sum = 0;
            for (double v : ms) sum += v;
            std::sort(ms.begin(), ms.end());
            const double avg = sum / double(ms.size());
            frames["avg_ms"] = avg;
            frames["p50_ms"] = ms[ms.size() / 2];
            frames["p99_ms"] = ms[std::min(ms.size() - 1, size_t(double(ms.size()) * 0.99))];
            frames["max_ms"] = ms.back();
            frames["rendered_fps"] = 1000.0 / avg;
            const double mult = m_multiplierCount ? m_multiplierSum / double(m_multiplierCount) : 1.0;
            frames["avg_frame_gen_multiplier"] = mult;
            frames["presented_fps_estimate"] = 1000.0 / avg * (mult < 1.0 ? 1.0 : mult);
        }
        root["frames"] = frames;

        Json::Value passes(Json::objectValue);
        for (const auto& [name, stat] : m_profiler.Stats())
        {
            Json::Value p(Json::objectValue);
            p["avg_ms"] = stat.AvgMs();
            p["max_ms"] = stat.maxMs;
            p["samples"] = Json::Value::UInt64(stat.count);
            passes[name] = p;
        }
        root["gpu_passes"] = passes;
        root["vram"] = QueryVram(device);

        fs::path out = m_options.benchOut;
        if (out.empty())
            out = RepoRoot() / "Tools" / "out" / ("bench_" + (m_options.camera.empty() ? std::string("default") : m_options.camera) + ".json");
        if (WriteJson(out, root))
            donut::log::info("Bench written: %s", out.string().c_str());
        else
            donut::log::error("Failed to write bench JSON to %s", out.string().c_str());
    }

    void Automation::EndFrame(nvrhi::IDevice* device, donut::engine::CommonRenderPasses* commonPasses, nvrhi::ITexture* sdrPreview, const Json::Value& meta)
    {
        bool failed = false;

        if (m_benchRecording && !m_benchDone)
        {
            m_multiplierSum += meta.get("frame_gen_multiplier", 1).asDouble();
            m_multiplierCount++;
        }

        if (m_screenshotPending)
        {
            device->waitForIdle();
            failed |= !WriteScreenshot(device, commonPasses, sdrPreview);
            fs::path sidecar = m_options.screenshotPath;
            sidecar += ".json"; // camera, resolution, DLSS/HDR state of this capture
            WriteJson(sidecar, meta);
            m_screenshotPending = false;
            m_screenshotDone = true;
            m_hdrStaging = nullptr;
        }

        if (BenchRequested() && !m_benchDone && m_benchRecording &&
            std::chrono::duration<float>(std::chrono::steady_clock::now() - m_benchStart).count() >= m_options.benchSeconds)
        {
            // let the last timer queries land: cycle through every ring slot once the GPU is idle
            device->waitForIdle();
            for (int i = 0; i < 6; i++)
                m_profiler.BeginFrame();
            m_profiler.SetRecording(false);
            WriteBench(device, meta);
            m_benchDone = true;
        }

        const bool allDone = (!ScreenshotRequested() || m_screenshotDone) && (!BenchRequested() || m_benchDone);
        // Results are on disk at this point. TerminateProcess instead of std::exit: CRT/DLL teardown (Streamline, NGX)
        // with the device and its threads still alive crashed with an access violation after 4K runs.
        if (Enabled() && (allDone || failed))
            TerminateProcess(GetCurrentProcess(), failed ? 1u : 0u);
    }
}
