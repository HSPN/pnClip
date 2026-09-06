#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace pnclip {

enum class PixelFormat : std::uint8_t {
    rgba8,
    bgra8,
};

enum class CaptureFormat : std::uint8_t {
    pngGif,
    webP,
};

struct Point {
    double x{};
    double y{};
};

struct Rect {
    double x{};
    double y{};
    double width{};
    double height{};

    [[nodiscard]] constexpr bool empty() const noexcept {
        return width <= 0.0 || height <= 0.0;
    }
};

struct PixelBuffer {
    std::uint32_t width{};
    std::uint32_t height{};
    std::uint32_t stride{};
    PixelFormat format{PixelFormat::bgra8};
    std::vector<std::byte> bytes;

    [[nodiscard]] bool valid() const noexcept;
};

struct CapturedFrame {
    PixelBuffer image;
    std::chrono::steady_clock::time_point timestamp;
};

struct CaptureSettings {
    std::filesystem::path destinationFolder;
    std::string filenamePrefix{"PNClip"};
    CaptureFormat format{CaptureFormat::pngGif};
    std::chrono::milliseconds maximumDuration{5000};
    std::uint32_t framesPerSecond{24};
    bool nativeScale{};
};

[[nodiscard]] constexpr Rect rectBetween(Point first, Point second) noexcept {
    const auto left = first.x < second.x ? first.x : second.x;
    const auto bottom = first.y < second.y ? first.y : second.y;
    const auto right = first.x < second.x ? second.x : first.x;
    const auto top = first.y < second.y ? second.y : first.y;
    return {left, bottom, right - left, top - bottom};
}

[[nodiscard]] constexpr std::string_view stillImageExtension(CaptureFormat format) noexcept {
    return format == CaptureFormat::webP ? "webp" : "png";
}

[[nodiscard]] constexpr std::string_view animatedImageExtension(CaptureFormat format) noexcept {
    return format == CaptureFormat::webP ? "webp" : "gif";
}

}  // namespace pnclip
