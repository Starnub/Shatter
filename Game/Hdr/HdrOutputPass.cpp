#include "HdrOutputPass.h"

using namespace donut::math;

namespace shatter
{
    // Must match cbuffer HdrParams in Shaders/HdrOutput.hlsl
    struct HdrOutputConstants
    {
        float4   exposureRow0;
        float4   exposureRow1;
        float4   exposureRow2;
        float    autoExposureScale;
        float    paperWhiteNits;
        float    peakNits;
        uint32_t mode;
    };

    HdrOutputPass::HdrOutputPass(nvrhi::IDevice* device, std::shared_ptr<donut::engine::ShaderFactory> shaderFactory,
                                 std::shared_ptr<donut::engine::CommonRenderPasses> commonPasses)
        : m_device(device)
        , m_commonPasses(std::move(commonPasses))
    {
        m_pixelShader = shaderFactory->CreateShader("shatter/Shaders/HdrOutput.hlsl", "main_ps", nullptr, nvrhi::ShaderType::Pixel);

        nvrhi::BindingLayoutDesc layoutDesc;
        layoutDesc.visibility = nvrhi::ShaderType::Pixel;
        layoutDesc.bindings = {
            nvrhi::BindingLayoutItem::VolatileConstantBuffer(0),
            nvrhi::BindingLayoutItem::Texture_SRV(0),
            nvrhi::BindingLayoutItem::Sampler(0)
        };
        m_bindingLayout = m_device->createBindingLayout(layoutDesc);

        nvrhi::BufferDesc cbDesc;
        cbDesc.byteSize = sizeof(HdrOutputConstants);
        cbDesc.debugName = "HdrOutputConstants";
        cbDesc.isConstantBuffer = true;
        cbDesc.isVolatile = true;
        cbDesc.maxVersions = 16;
        m_constantBuffer = m_device->createBuffer(cbDesc);

        nvrhi::SamplerDesc samplerDesc;
        samplerDesc.setAllFilters(true);
        samplerDesc.setAllAddressModes(nvrhi::SamplerAddressMode::Clamp);
        m_sampler = m_device->createSampler(samplerDesc);
    }

    void HdrOutputPass::Render(nvrhi::ICommandList* commandList, nvrhi::IFramebuffer* target, nvrhi::ITexture* source,
                               const Params& params, donut::engine::BindingCache& bindingCache)
    {
        const nvrhi::FramebufferInfoEx& fbInfo = target->getFramebufferInfo();
        const nvrhi::Format targetFormat = fbInfo.colorFormats[0];

        nvrhi::GraphicsPipelineHandle& pso = m_pipelines[targetFormat];
        if (!pso)
        {
            nvrhi::GraphicsPipelineDesc desc;
            desc.primType = nvrhi::PrimitiveType::TriangleStrip;
            desc.VS = m_commonPasses->m_FullscreenVS;
            desc.PS = m_pixelShader;
            desc.bindingLayouts = { m_bindingLayout };
            desc.renderState.rasterState.setCullNone();
            desc.renderState.depthStencilState.depthTestEnable = false;
            desc.renderState.depthStencilState.stencilEnable = false;
            pso = m_device->createGraphicsPipeline(desc, target);
        }

        nvrhi::BindingSetDesc bindingSetDesc;
        bindingSetDesc.bindings = {
            nvrhi::BindingSetItem::ConstantBuffer(0, m_constantBuffer),
            nvrhi::BindingSetItem::Texture_SRV(0, source),
            nvrhi::BindingSetItem::Sampler(0, m_sampler)
        };
        nvrhi::BindingSetHandle bindingSet = bindingCache.GetOrCreateBindingSet(bindingSetDesc, m_bindingLayout);

        HdrOutputConstants constants = {};
        constants.exposureRow0 = float4(params.colorTransform.row0, 0.f);
        constants.exposureRow1 = float4(params.colorTransform.row1, 0.f);
        constants.exposureRow2 = float4(params.colorTransform.row2, 0.f);
        constants.autoExposureScale = params.autoExposureScale;
        constants.paperWhiteNits = params.paperWhiteNits;
        constants.peakNits = params.peakNits;
        constants.mode = (uint32_t)params.mode;
        commandList->writeBuffer(m_constantBuffer, &constants, sizeof(constants));

        nvrhi::GraphicsState state;
        state.pipeline = pso;
        state.framebuffer = target;
        state.bindings = { bindingSet };
        state.viewport.addViewportAndScissorRect(fbInfo.getViewport());
        commandList->setGraphicsState(state);

        nvrhi::DrawArguments args;
        args.instanceCount = 1;
        args.vertexCount = 4;
        commandList->draw(args);
    }
}
