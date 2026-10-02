// SHATTER: final output pass. Exposed linear Rec.709 scene color -> GT7 tone mapping -> Rec.2020 -> PQ (HDR10)
// or sRGB (SDR preview used for PNG screenshots).
//
// GT7 tone mapper: HLSL port of Polyphony Digital's gt7_tone_mapping.cpp (SIGGRAPH 2025 shading course),
// MIT License, Copyright (c) 2025 Polyphony Digital Inc. See Game/gt7_tone_mapping.cpp for the original and license text.
// Only the ICtCp unified color space is ported (TONE_MAPPING_UCS_ICTCP).

cbuffer HdrParams : register(b0)
{
    float4 g_ExposureRow0;      // 3x3 color transform (exposure compensation, white balance), rows in xyz
    float4 g_ExposureRow1;
    float4 g_ExposureRow2;
    float  g_AutoExposureScale; // 1 when auto exposure is off
    float  g_PaperWhiteNits;    // nits that a scene value of 1.0 (after exposure) is shown at
    float  g_PeakNits;          // display peak (HDR mode only, >= 250)
    uint   g_Mode;              // 0 = HDR10 PQ, 1 = SDR preview (sRGB)
};

Texture2D<float4> t_Color : register(t0);
SamplerState      s_Linear : register(s0);

// GT7 constants. 1.0 in the "frame buffer" scale = 100 nits.
static const float REFERENCE_LUMINANCE = 100.0;
static const float SDR_PAPER_WHITE     = 250.0;

float smoothStepGT(float x, float edge0, float edge1)
{
    float t = (x - edge0) / (edge1 - edge0);
    if (x < edge0) return 0.0;
    if (x > edge1) return 1.0;
    return t * t * (3.0 - 2.0 * t);
}

float chromaCurve(float x, float a, float b) { return 1.0 - smoothStepGT(x, a, b); }

struct GTCurve
{
    float peak, alpha, midPoint, linearSection, toeStrength, kA, kB, kC;

    float eval(float x)
    {
        if (x < 0.0) return 0.0;
        float weightLinear = smoothStepGT(x, 0.0, midPoint);
        float weightToe = 1.0 - weightLinear;
        float shoulder = kA + kB * exp(x * kC);
        if (x < linearSection * peak)
        {
            float toeMapped = midPoint * pow(x / midPoint, toeStrength);
            return weightToe * toeMapped + weightLinear * x;
        }
        return shoulder;
    }
};

GTCurve makeCurve(float monitorIntensity, float alpha, float grayPoint, float linearSection, float toeStrength)
{
    GTCurve c;
    c.peak = monitorIntensity; c.alpha = alpha; c.midPoint = grayPoint;
    c.linearSection = linearSection; c.toeStrength = toeStrength;
    float k = (linearSection - 1.0) / (alpha - 1.0);
    c.kA = monitorIntensity * linearSection + monitorIntensity * k;
    c.kB = -monitorIntensity * k * exp(linearSection / k);
    c.kC = -1.0 / (k * monitorIntensity);
    return c;
}

float eotfST2084(float n)
{
    n = saturate(n);
    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float np = pow(n, 1.0 / m2);
    float l = max(np - c1, 0.0);
    l = l / (c2 - c3 * np);
    l = pow(l, 1.0 / m1);
    return l * 10000.0 / REFERENCE_LUMINANCE;
}

float inverseEotfST2084(float v)
{
    const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float y = (v * REFERENCE_LUMINANCE) / 10000.0;
    float ym = pow(y, m1);
    return exp2(m2 * (log2(c1 + c2 * ym) - log2(1.0 + c3 * ym)));
}

float3 rgbToICtCp(float3 rgb) // linear Rec.2020
{
    float l = (rgb.r * 1688.0 + rgb.g * 2146.0 + rgb.b * 262.0) / 4096.0;
    float m = (rgb.r * 683.0 + rgb.g * 2951.0 + rgb.b * 462.0) / 4096.0;
    float s = (rgb.r * 99.0 + rgb.g * 309.0 + rgb.b * 3688.0) / 4096.0;
    float lPQ = inverseEotfST2084(l), mPQ = inverseEotfST2084(m), sPQ = inverseEotfST2084(s);
    return float3((2048.0 * lPQ + 2048.0 * mPQ) / 4096.0,
                  (6610.0 * lPQ - 13613.0 * mPQ + 7003.0 * sPQ) / 4096.0,
                  (17933.0 * lPQ - 17390.0 * mPQ - 543.0 * sPQ) / 4096.0);
}

float3 iCtCpToRgb(float3 ict)
{
    float l = ict.x + 0.00860904 * ict.y + 0.11103 * ict.z;
    float m = ict.x - 0.00860904 * ict.y - 0.11103 * ict.z;
    float s = ict.x + 0.560031 * ict.y - 0.320627 * ict.z;
    float lL = eotfST2084(l), mL = eotfST2084(m), sL = eotfST2084(s);
    return max(float3(3.43661 * lL - 2.50645 * mL + 0.0698454 * sL,
                      -0.79133 * lL + 1.9836 * mL - 0.192271 * sL,
                      -0.0259499 * lL - 0.0989137 * mL + 1.12486 * sL), 0.0);
}

// Input: linear Rec.2020 in frame buffer units (1.0 = 100 nits). Output: tone mapped, same units.
// targetNits: HDR peak, or SDR_PAPER_WHITE for SDR. Returns values in [0, target].
float3 gt7ToneMap(float3 rgb, float targetNits, float sdrCorrection)
{
    const float blendRatio = 0.6, fadeStart = 0.98, fadeEnd = 1.16;
    float fbTarget = targetNits / REFERENCE_LUMINANCE;
    GTCurve curve = makeCurve(fbTarget, 0.25, 0.538, 0.444, 1.280);
    float targetUcs = rgbToICtCp(float3(fbTarget, fbTarget, fbTarget)).x;

    float3 ucs = rgbToICtCp(rgb);
    float3 skewed = float3(curve.eval(rgb.r), curve.eval(rgb.g), curve.eval(rgb.b));
    float3 skewedUcs = rgbToICtCp(skewed);

    float chromaScale = chromaCurve(ucs.x / targetUcs, fadeStart, fadeEnd);
    float3 scaledUcs = float3(skewedUcs.x, ucs.y * chromaScale, ucs.z * chromaScale);
    float3 scaled = iCtCpToRgb(scaledUcs);

    float3 blended = (1.0 - blendRatio) * skewed + blendRatio * scaled;
    return sdrCorrection * min(blended, fbTarget);
}

static const float3x3 Rec709ToRec2020 = float3x3(
    0.6274039, 0.3292830, 0.0433131,
    0.0690973, 0.9195404, 0.0113623,
    0.0163914, 0.0880133, 0.8955953);

float3 srgbOetf(float3 c)
{
    c = saturate(c);
    return select(c <= 0.0031308, c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055);
}

void main_ps(in float4 pos : SV_Position, in float2 uv : UV, out float4 o_rgba : SV_Target)
{
    float3 c = t_Color.SampleLevel(s_Linear, uv, 0).rgb;
    c = (all(isfinite(c))) ? max(c, 0.0) : float3(0, 0, 0);

    c = float3(dot(g_ExposureRow0.xyz, c), dot(g_ExposureRow1.xyz, c), dot(g_ExposureRow2.xyz, c)) * g_AutoExposureScale;

    // Scene value 1.0 -> paper white; GT7 frame buffer units are 1.0 = 100 nits.
    float3 fb = mul(Rec709ToRec2020, c) * (g_PaperWhiteNits / REFERENCE_LUMINANCE);

    if (g_Mode == 0)
    {
        float3 mapped = gt7ToneMap(fb, g_PeakNits, 1.0);
        o_rgba = float4(saturate(float3(inverseEotfST2084(mapped.r), inverseEotfST2084(mapped.g), inverseEotfST2084(mapped.b))), 1.0);
    }
    else
    {
        // SDR preview: GT7 SDR path (250 nit reference), back to Rec.709 for sRGB encode.
        float sdrCorrection = 1.0 / (SDR_PAPER_WHITE / REFERENCE_LUMINANCE);
        float3 mapped = gt7ToneMap(mul(Rec709ToRec2020, c) * (SDR_PAPER_WHITE / REFERENCE_LUMINANCE), SDR_PAPER_WHITE, sdrCorrection);
        static const float3x3 Rec2020ToRec709 = float3x3(
             1.6604910, -0.5876411, -0.0728499,
            -0.1245505,  1.1328999, -0.0083494,
            -0.0181508, -0.1005789,  1.1187297);
        o_rgba = float4(srgbOetf(mul(Rec2020ToRec709, mapped)), 1.0);
    }
}
