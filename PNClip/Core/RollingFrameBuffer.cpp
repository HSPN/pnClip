#include "RollingFrameBuffer.hpp"

#include <utility>

namespace pnclip {

RollingFrameBuffer::RollingFrameBuffer(std::chrono::milliseconds duration)
    : duration_(duration) {}

void RollingFrameBuffer::push(CapturedFrame frame) {
    byteSize_ += frame.image.bytes.size();
    frames_.push_back(std::move(frame));
    discardExpired();
}

void RollingFrameBuffer::clear() noexcept {
    frames_.clear();
    byteSize_ = 0;
}

std::vector<CapturedFrame> RollingFrameBuffer::snapshot() const {
    return {frames_.begin(), frames_.end()};
}

std::size_t RollingFrameBuffer::size() const noexcept {
    return frames_.size();
}

std::size_t RollingFrameBuffer::byteSize() const noexcept {
    return byteSize_;
}

void RollingFrameBuffer::discardExpired() {
    if (frames_.empty()) return;
    const auto cutoff = frames_.back().timestamp - duration_;
    while (!frames_.empty() && frames_.front().timestamp < cutoff) {
        byteSize_ -= frames_.front().image.bytes.size();
        frames_.pop_front();
    }
}

}  // namespace pnclip
