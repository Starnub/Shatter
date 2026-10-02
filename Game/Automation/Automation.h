// SHATTER: automation hooks used while iterating (PLAN section 10):
//   --camera <preset>               named camera presets (Game/camera_presets.json)
//   --bench <seconds>               per-pass GPU ms + VRAM + frame times -> JSON, then exit
//   --screenshot <path> --frame N   tonemapped SDR PNG at <path> + scene-referred EXR at <path>.exr, then exit
#pragma once

#include <chrono>
#include <string>
#include <vector>

#include <nvrhi/nvrhi.h>
#include <json/json.h>
#include <donut/engine/CommonRenderPasses.h>

#include "GpuProfiler.h"

namespace shatter
{
    struct AutomationOptions
    {
        float benchSeconds = 0.f;
        std::string benchOut;
        std::string camera;
        std::string screenshotPath;
        int frame = 64;
    };

    class Automation
    {
    public:
        explicit Automation(const AutomationOptions& options) : m_options(options) {}

        bool BenchRequested() const { return m_options.benchSeconds > 0.f; }
        bool ScreenshotRequested() const { return !m_options.screenshotPath.empty(); }
        bool Enabled() const { return BenchRequested() || ScreenshotRequested(); }
        const AutomationOptions& Options() const { return m_options; }
        GpuProfiler& Profiler() { return m_profiler; }

        // Camera presets: "x,y,z,dx,dy,dz,ux,uy,uz" (the format of the Camera panel's clipboard buttons), per scene.
        static std::string LoadCameraPreset(const std::string& scene, const std::string& name);
        static bool SaveCameraPreset(const std::string& scene, const std::string& name, const std::string& posDirUp);

        // Once per rendered frame, before recording commands. 'sceneReady' = loaded and nothing async pending.
        void BeginFrame(bool sceneReady);

        // True on the frame the screenshot must be recorded.
        bool CaptureThisFrame() const { return ScreenshotRequested() && !m_screenshotDone && m_framesReady == m_options.frame; }

        // Records GPU->staging copies of the scene-referred HDR source and the SDR preview into the open command list.
        void RecordCapture(nvrhi::IDevice* device, nvrhi::ICommandList* commandList, nvrhi::ITexture* hdrSource, nvrhi::ITexture* sdrPreview);

        // After the command list has been executed. Writes files; exits the process once every requested task is done.
        // 'meta' is merged into the bench JSON (resolution, DLSS mode, display info, ...).
        void EndFrame(nvrhi::IDevice* device, donut::engine::CommonRenderPasses* commonPasses, nvrhi::ITexture* sdrPreview, const Json::Value& meta);

        static Json::Value QueryVram(nvrhi::IDevice* device);

    private:
        void WriteBench(nvrhi::IDevice* device, const Json::Value& meta);
        bool WriteScreenshot(nvrhi::IDevice* device, donut::engine::CommonRenderPasses* commonPasses, nvrhi::ITexture* sdrPreview);

        AutomationOptions m_options;
        GpuProfiler m_profiler;

        int m_framesReady = 0;
        bool m_screenshotDone = false;
        bool m_screenshotPending = false;
        bool m_benchDone = false;

        static constexpr int kBenchWarmupFrames = 120;
        bool m_benchRecording = false;
        std::chrono::steady_clock::time_point m_benchStart;
        std::chrono::steady_clock::time_point m_lastFrame;
        std::vector<double> m_cpuFrameMs;
    double m_multiplierSum = 0.0;
    uint64_t m_multiplierCount = 0;

        nvrhi::StagingTextureHandle m_hdrStaging;
        nvrhi::Format m_hdrFormat = nvrhi::Format::UNKNOWN;
        uint32_t m_hdrWidth = 0, m_hdrHeight = 0;
    };
}
