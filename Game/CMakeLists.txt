# Shatter game code: lives next to the RTXPT root and is linked into RtxptCore (see Rtxpt/CMakeLists.txt, marked SHATTER).

include(${CMAKE_SOURCE_DIR}/External/Donut/compileshaders.cmake)

file(GLOB_RECURSE shatter_shader_sources "Shaders/*.hlsl" "Shaders/*.hlsli")
file(GLOB_RECURSE shatter_sources "*.cpp" "*.h")
list(REMOVE_ITEM shatter_sources "${CMAKE_CURRENT_SOURCE_DIR}/gt7_tone_mapping.cpp") # reference only, has its own main()

# SM 6.6+ is required (64-bit atomics, WaveSize); 6.9 with Agility SDK >= 1.619
set(shatter_shadermake_options "-m 6_6")
if(RTXPT_D3D_AGILITY_SDK_VERSION AND (RTXPT_D3D_AGILITY_SDK_VERSION GREATER_EQUAL "619"))
    set(shatter_shadermake_options "-m 6_9")
endif()

donut_compile_shaders(
    TARGET shatter_shaders
    CONFIG ${CMAKE_CURRENT_SOURCE_DIR}/shaders.cfg
    SOURCES ${shatter_shader_sources}
    FOLDER "Shatter"
    DXIL ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/ShaderPrecompiled/Shatter/dxil  # D3D12 only (CLAUDE.md); no SPIR-V
    INCLUDES ${CMAKE_SOURCE_DIR}/External  # <NVAPI/nvHLSLExtns.h>
    SHADERMAKE_OPTIONS ${shatter_shadermake_options}
)

add_library(ShatterGame STATIC ${shatter_sources})
target_link_libraries(ShatterGame PUBLIC donut_render donut_app donut_engine)
target_include_directories(ShatterGame PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
add_dependencies(ShatterGame shatter_shaders)
set_target_properties(ShatterGame PROPERTIES FOLDER "Shatter")
source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} FILES ${shatter_sources} ${shatter_shader_sources})
