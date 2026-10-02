// SHATTER: final HDR output: exposed scene color -> GT7 tone map -> Rec.2020 PQ (HDR10 swapchain),
// or an SDR preview used for PNG screenshots.
#pragma once

#include <memory>
#include <unordered_map>

#include <nvrhi/nvrhi.h>
#include <donut/core/math/math.h>
#include <donut/engine/BindingCache.h>
#include <donut/engine/CommonRenderPasses.h>
#include <donut/engine/ShaderFactory.h>

namespace shatter
{
    struct HdrSettings
    {
        float paperWhiteNits = 200.f;        // nits a scene value of 1.0 is displayed at
        bool  peakOverrideEnabled = false;   // in-game override of the Windows-reported peak
        float peakOverrideNits = 700.f;

        // Filled each frame from DXGI_OUTPUT_DESC1 (calibrated by the Windows HDR Calibration app)
        bool  displayHdrActive = false;
        float displayPeakNits = 0.f;
        float displayFullFrameNits = 0.f;

        // GT7 needs a peak of at least 250 nits. Windows reported 7600 for the C2 here (uncalibrated / EDID value), which
        // would turn tone mapping into a no-op, so anything outside 250..1500 is treated as unusable and replaced by ~700.
        float EffectivePeakNits() const
        {
            const bool reportedOk = displayPeakNits >= 250.f && displayPeakNits <= 1500.f;
            const float peak = peakOverrideEnabled ? peakOverrideNits : (reportedOk ? displayPeakNits : 700.f);
            return peak < 250.f ? 250.f : peak;
        }
    };

    class HdrOutputPass
    {
    public:
        enum class Mode : uint32_t { HDR10 = 0, SdrPreview = 1 };

        struct Params
        {
            donut::math::float3x3 colorTransform = donut::math::float3x3::identity(); // exposure compensation, white balance
            float autoExposureScale = 1.f;
            float paperWhiteNits = 200.f;
            float peakNits = 700.f;
            Mode  mode = Mode::HDR10;
        };

        HdrOutputPass(nvrhi::IDevice* device, std::shared_ptr<donut::engine::ShaderFactory> shaderFactory,
                      std::shared_ptr<donut::engine::CommonRenderPasses> commonPasses);

        // Draws a full-screen pass into 'target'. 'source' is linear Rec.709 scene color (pre-exposure).
        void Render(nvrhi::ICommandList* commandList, nvrhi::IFramebuffer* target, nvrhi::ITexture* source,
                    const Params& params, donut::engine::BindingCache& bindingCache);

    private:
        nvrhi::IDevice* m_device;
        std::shared_ptr<donut::engine::CommonRenderPasses> m_commonPasses;
        nvrhi::ShaderHandle m_pixelShader;
        nvrhi::BindingLayoutHandle m_bindingLayout;
        nvrhi::BufferHandle m_constantBuffer;
        nvrhi::SamplerHandle m_sampler;
        std::unordered_map<nvrhi::Format, nvrhi::GraphicsPipelineHandle> m_pipelines; // one per target format
    };
}
