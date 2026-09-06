#pragma once
#include "ImageEncoder.hpp"
namespace pnclip {
class WebPEncoder final : public ImageEncoder {
public:
    [[nodiscard]] EncodeResult encode(std::span<const PixelBuffer> frames,
        std::span<const std::chrono::milliseconds> durations) const override;
};
}
