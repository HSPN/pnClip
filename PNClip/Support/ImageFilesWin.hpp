#pragma once
#include "../Core/PlatformServices.hpp"
#include <string>
#include <windows.h>
namespace pnclip {
std::wstring wide(const std::string &text);
std::string utf8(const std::wstring &text);
std::filesystem::path desktopFolder();
std::filesystem::path nextCapturePath(const CaptureSettings &settings, bool animated);
ServiceError saveStillWin(const PixelBuffer &image, const CaptureSettings &settings,
                          std::filesystem::path &path);
ServiceError saveAnimationWin(const std::vector<PixelBuffer> &frames,
                              const std::vector<std::chrono::milliseconds> &durations,
                              const CaptureSettings &settings, std::filesystem::path &path);
PixelBuffer resizeImageWin(const PixelBuffer &image, unsigned width, unsigned height);
double monitorScaleWin(HMONITOR monitor);
} // namespace pnclip
