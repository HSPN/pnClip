#pragma once

#include "CaptureTypes.hpp"

#include <chrono>
#include <cstddef>
#include <deque>
#include <vector>

namespace pnclip {

class RollingFrameBuffer {
public:
    explicit RollingFrameBuffer(std::chrono::milliseconds duration);

    void push(CapturedFrame frame);
    void clear() noexcept;

    [[nodiscard]] std::vector<CapturedFrame> snapshot() const;
    [[nodiscard]] std::size_t size() const noexcept;
    [[nodiscard]] std::size_t byteSize() const noexcept;

private:
    void discardExpired();

    std::chrono::milliseconds duration_;
    std::deque<CapturedFrame> frames_;
    std::size_t byteSize_{};
};

}  // namespace pnclip
