#include "GifEncoder.hpp"
#include "GifColorPipeline.hpp"
#include "GifLzwEncoder.hpp"
#include <algorithm>
#include <cmath>
namespace pnclip {
namespace {
void byte(std::vector<std::byte> &out, std::uint8_t value) { out.push_back((std::byte)value); }
void word(std::vector<std::byte> &out, std::uint16_t value) {
    byte(out, value & 0xff);
    byte(out, value >> 8);
}
void bytes(std::vector<std::byte> &out, std::initializer_list<std::uint8_t> values) {
    for (auto value : values)
        byte(out, value);
}
std::uint8_t component(const PixelBuffer &frame, std::size_t offset, int channel) {
    if (frame.format == PixelFormat::rgba8)
        return std::to_integer<std::uint8_t>(frame.bytes[offset + channel]);
    static constexpr int bgra[] = {2, 1, 0};
    return std::to_integer<std::uint8_t>(frame.bytes[offset + bgra[channel]]);
}
std::vector<std::uint8_t> rgbaBytes(const PixelBuffer &frame) {
    std::vector<std::uint8_t> rgba((std::size_t)frame.width * frame.height * 4);
    for (std::uint32_t y = 0; y < frame.height; ++y)
        for (std::uint32_t x = 0; x < frame.width; ++x) {
            const auto source = (std::size_t)y * frame.stride + x * 4;
            const auto destination = ((std::size_t)y * frame.width + x) * 4;
            for (int c = 0; c < 3; ++c)
                rgba[destination + c] = component(frame, source, c);
            rgba[destination + 3] = 255;
        }
    return rgba;
}
} // namespace
EncodeResult GifEncoder::encode(std::span<const PixelBuffer> frames,
                                std::span<const std::chrono::milliseconds> durations) const {
    if (frames.empty() || frames.size() != durations.size())
        return {{}, {1, "No frames"}};
    const auto width = frames.front().width, height = frames.front().height;
    if (!frames.front().valid() || width > UINT16_MAX || height > UINT16_MAX)
        return {{}, {2, "Unsupported dimensions"}};
    for (const auto &frame : frames)
        if (!frame.valid() || frame.width != width || frame.height != height)
            return {{}, {3, "Frame dimensions differ"}};
    gif_detail::ColorQuantizer quantizer;
    const double totalPixels = (double)width * height * frames.size();
    const auto sampleStep = (std::size_t)std::max(1.0, std::ceil(std::sqrt(totalPixels / 1500000.0)));
    for (const auto &frame : frames) {
        auto rgba = rgbaBytes(frame);
        quantizer.addRGBABytes(rgba.data(), width, height, width * 4, sampleStep);
    }
    const auto palette = quantizer.makePalette(256);
    gif_detail::Ditherer ditherer(palette);
    std::vector<std::byte> out;
    for (char c : std::string_view{"GIF89a"})
        byte(out, (std::uint8_t)c);
    word(out, width);
    word(out, height);
    bytes(out, {0xf7, 0, 0});
    for (auto color : palette)
        byte(out, color);
    bytes(out,
          {0x21, 0xff, 0x0b, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0', 0x03, 0x01, 0, 0, 0});
    long long elapsedMilliseconds = 0;
    long long previousTick = 0;
    for (std::size_t index = 0; index < frames.size(); ++index) {
        elapsedMilliseconds += durations[index].count();
        const auto tick = std::llround(elapsedMilliseconds / 10.0);
        auto delay = (std::uint16_t)std::clamp<long long>(tick - previousTick, 1, UINT16_MAX);
        previousTick = tick;
        bytes(out, {0x21, 0xf9, 0x04, 0});
        word(out, delay);
        bytes(out, {0, 0, 0x2c});
        word(out, 0);
        word(out, 0);
        word(out, width);
        word(out, height);
        bytes(out, {0, 8});
        auto rgba = rgbaBytes(frames[index]);
        auto indexed = ditherer.indexedPixels(rgba.data(), width, height, width * 4);
        auto blocks = gifLzwEncode(indexed);
        out.insert(out.end(), blocks.begin(), blocks.end());
    }
    byte(out, 0x3b);
    return {std::move(out), {}};
}
} // namespace pnclip
