#pragma once

#include "CaptureTypes.hpp"

#include <chrono>
#include <filesystem>
#include <span>
#include <string>
#include <vector>

namespace pnclip {

struct EncodingError {
    int code{};
    std::string message;
};

struct EncodeResult {
    std::vector<std::byte> data;
    EncodingError error;

    [[nodiscard]] explicit operator bool() const noexcept { return error.code == 0; }
};

class ImageEncoder {
public:
    virtual ~ImageEncoder() = default;
    [[nodiscard]] virtual EncodeResult encode(
        std::span<const PixelBuffer> frames,
        std::span<const std::chrono::milliseconds> durations) const = 0;
};

[[nodiscard]] bool writeFileAtomically(const std::filesystem::path& destination,
                                       std::span<const std::byte> data,
                                       EncodingError& error);

}  // namespace pnclip
