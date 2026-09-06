#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace pnclip {

[[nodiscard]] std::vector<std::byte> gifLzwEncode(
    std::span<const std::uint8_t> pixels, std::uint8_t minimumCodeSize = 8);

}  // namespace pnclip
