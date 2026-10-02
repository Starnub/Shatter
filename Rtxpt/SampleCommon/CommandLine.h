/*
* Copyright (c) 2025, NVIDIA CORPORATION.  All rights reserved.
*
* NVIDIA CORPORATION and its licensors retain all intellectual property
* and proprietary rights in and to this software, related documentation
* and any modifications thereto.  Any use, reproduction, disclosure or
* distribution of this software and related documentation without an express
* license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#pragma once

#include <string>
#include <optional>

struct CommandLineOptions
{
	std::string scene;
	bool nonInteractive = false;
	bool noWindow = false;
	bool debug = false;
	uint32_t width = 1920;
	uint32_t height = 1080;
	bool fullscreen = false;
	std::string adapter;
    int adapterIndex = -1;
	bool useVulkan = false;
    bool stopAnimations = false;
	bool disableSER = false;

    // SHATTER: automation + output
    bool sdr = false;                  // --sdr: original sRGB swapchain instead of HDR10 (debugging only)
    float bench = 0.0f;                // --bench <seconds>: run, write bench JSON, exit
    std::string benchOut = "";         // --benchOut <path>
    std::string camera = "";           // --camera <preset name>
    std::string screenshot = "";       // --screenshot <path>: writes <path> (SDR PNG) and <path>.exr
    int fg = 0;                        // --fg N: initial frame generation item: 0 off, 1 2x, 2 3x, 3 4x, 4 5x, 5 6x, 6 Dynamic
    int frame = 64;                    // --frame N: frame (after scene load) at which --screenshot is taken
    // SHATTER: point clouds (M1); negative = keep the default
    bool noPoints = false;             // --noPoints
    int pointsM = -1;                  // --pointsM N: total points in millions
    int pointClouds = -1;              // --pointClouds N
    int pointAtomic = -1;              // --pointAtomic 0|1: 0 int64 fixed point, 1 NVAPI fp16x4
    int pointLod = -1;                 // --pointLod 0|1
    int pointAgg = -1;                 // --pointAgg 0|1: wave pre-aggregation
    float pointPpp = -1.f;             // --pointPpp X: LOD cap in points per pixel
    int pointGrid = -1;                // --pointGrid N: density grid log2 resolution

    std::string capturePath = "";
    bool captureSimple = false;
    bool captureSequence = false;
    float sequenceWarmupStart = 0;
    float sequenceRecordStart = 0;
    float sequenceFPS = 60.0f;
    int sequenceFrameCount = 0;

    std::string cameraPosDirUp = "";

    int  UseNEE                     = 1;
    int  NEEType                    = 2;
    int  UseReSTIRDI                = false;
    int  UseReSTIRGI                = true;
    int  RealtimeSamplesPerPixel    = 1;
    int  ReferenceSamplesPerPixel   = 4096;
    int  StandaloneDenoiser         = true;
    int  RealtimeAA                 = 3;

    bool OverrideToRealtimeMode     = false;
    bool OverrideToReferenceMode    = false;

    bool OverrideAutoexposureOff    = false;
    float OverrideExposureOffset    = FLT_MAX;
    
    bool DisableFireflyFilters      = false;
    bool DisablePostProcessFilters  = false;

    std::string PropShowTags        = "";
    std::string PropCameraAttach    = "";

	CommandLineOptions(){}

	bool InitFromCommandLine(int argc, char const* const* argv);
};