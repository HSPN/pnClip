#include "CaptureTypes.hpp"

#include <limits>

namespace pnclip {

bool PixelBuffer::valid() const noexcept {
    if (width == 0 || height == 0 || stride < width * 4U) return false;
    if (height > std::numeric_limits<std::size_t>::max() / stride) return false;
    return bytes.size() >= static_cast<std::size_t>(stride) * height;
}

}  // namespace pnclip
