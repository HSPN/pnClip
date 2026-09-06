#include "GifEncoder.hpp"
#include "GifLzwEncoder.hpp"
#include <algorithm>
#include <cmath>
namespace pnclip {
namespace {
void byte(std::vector<std::byte>& out, std::uint8_t value) { out.push_back((std::byte)value); }
void word(std::vector<std::byte>& out, std::uint16_t value) {
    byte(out, value & 0xff); byte(out, value >> 8);
}
void bytes(std::vector<std::byte>& out, std::initializer_list<std::uint8_t> values) {
    for (auto value : values) byte(out, value);
}
std::uint8_t component(const PixelBuffer& frame, std::size_t offset, int channel) {
    if (frame.format == PixelFormat::rgba8) return std::to_integer<std::uint8_t>(frame.bytes[offset + channel]);
    static constexpr int bgra[] = {2, 1, 0};
    return std::to_integer<std::uint8_t>(frame.bytes[offset + bgra[channel]]);
}
}
EncodeResult GifEncoder::encode(std::span<const PixelBuffer> frames,
    std::span<const std::chrono::milliseconds> durations) const {
    if (frames.empty() || frames.size() != durations.size()) return {{}, {1, "No frames"}};
    const auto width = frames.front().width, height = frames.front().height;
    if (!frames.front().valid() || width > UINT16_MAX || height > UINT16_MAX)
        return {{}, {2, "Unsupported dimensions"}};
    for (const auto& frame : frames)
        if (!frame.valid() || frame.width != width || frame.height != height)
            return {{}, {3, "Frame dimensions differ"}};
    std::vector<std::byte> out;
    for (char c : std::string_view{"GIF89a"}) byte(out, (std::uint8_t)c);
    word(out, width); word(out, height); bytes(out, {0xf7, 0, 0});
    // Deterministic RGB 3-3-2 palette; both platforms produce identical output.
    for (int i = 0; i < 256; ++i) {
        byte(out, (std::uint8_t)(((i >> 5) & 7) * 255 / 7));
        byte(out, (std::uint8_t)(((i >> 2) & 7) * 255 / 7));
        byte(out, (std::uint8_t)((i & 3) * 255 / 3));
    }
    bytes(out, {0x21,0xff,0x0b,'N','E','T','S','C','A','P','E','2','.','0',0x03,0x01,0,0,0});
    long long elapsedMilliseconds = 0;
    long long previousTick = 0;
    for (std::size_t index = 0; index < frames.size(); ++index) {
        elapsedMilliseconds += durations[index].count();
        const auto tick = std::llround(elapsedMilliseconds / 10.0);
        auto delay = (std::uint16_t)std::clamp<long long>(tick - previousTick, 1, UINT16_MAX);
        previousTick = tick;
        bytes(out, {0x21,0xf9,0x04,0}); word(out, delay); bytes(out, {0,0,0x2c});
        word(out, 0); word(out, 0); word(out, width); word(out, height); bytes(out, {0,8});
        std::vector<std::uint8_t> indexed((std::size_t)width * height);
        for (std::uint32_t y = 0; y < height; ++y) for (std::uint32_t x = 0; x < width; ++x) {
            auto offset = (std::size_t)y * frames[index].stride + x * 4;
            auto r = component(frames[index], offset, 0);
            auto g = component(frames[index], offset, 1);
            auto b = component(frames[index], offset, 2);
            indexed[(std::size_t)y * width + x] = (r & 0xe0) | ((g & 0xe0) >> 3) | (b >> 6);
        }
        auto blocks = gifLzwEncode(indexed);
        out.insert(out.end(), blocks.begin(), blocks.end());
    }
    byte(out, 0x3b);
    return {std::move(out), {}};
}
}
