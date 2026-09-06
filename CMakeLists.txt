cmake_minimum_required(VERSION 3.24)
project(PNClip LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_path(WEBP_INCLUDE_DIR webp/encode.h HINTS ThirdParty/libwebp/include REQUIRED)
find_library(WEBP_LIBRARY NAMES webp libwebp HINTS ThirdParty/libwebp/lib REQUIRED)
find_library(WEBPMUX_LIBRARY NAMES webpmux libwebpmux HINTS ThirdParty/libwebp/lib REQUIRED)
find_library(SHARPYUV_LIBRARY NAMES sharpyuv libsharpyuv HINTS ThirdParty/libwebp/lib REQUIRED)

add_library(PNClipCore STATIC
    PNClip/Core/AppController.cpp
    PNClip/Core/CaptureTypes.cpp
    PNClip/Core/GifEncoder.cpp
    PNClip/Core/GifLzwEncoder.cpp
    PNClip/Core/ImageEncoder.cpp
    PNClip/Core/RollingFrameBuffer.cpp
    PNClip/Core/WebPEncoder.cpp
)
target_include_directories(PNClipCore PUBLIC PNClip/Core)
target_include_directories(PNClipCore PRIVATE ${WEBP_INCLUDE_DIR})
target_link_libraries(PNClipCore PUBLIC ${WEBPMUX_LIBRARY} ${WEBP_LIBRARY} ${SHARPYUV_LIBRARY})

add_executable(PNClipCoreTests Tests/CoreTests.cpp)
target_link_libraries(PNClipCoreTests PRIVATE PNClipCore)

include(CTest)
add_test(NAME PNClipCoreTests COMMAND PNClipCoreTests)

option(PNCLIP_BUILD_WINDOWS "Build Windows platform adapters" ${WIN32})
if(PNCLIP_BUILD_WINDOWS)
    if(NOT WIN32)
        message(FATAL_ERROR "Windows adapters require a Windows SDK and must be built on Windows")
    endif()

    add_library(PNClipPlatformWin STATIC
        PNClip/Capture/CaptureBackendWin.cpp
        PNClip/Support/PlatformCapabilitiesWin.cpp
        PNClip/Support/PlatformServicesWin.cpp
    )
    target_include_directories(PNClipPlatformWin PUBLIC PNClip/Core)
    target_link_libraries(PNClipPlatformWin PUBLIC PNClipCore windowsapp)
    target_compile_definitions(PNClipPlatformWin PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
endif()
