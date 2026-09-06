#include "GifLzwEncoder.hpp"

#include <algorithm>
#include <unordered_map>

namespace pnclip {
namespace {
class BitWriter {
public:
    void write(std::uint16_t code, int count) {
        bits_ |= static_cast<std::uint32_t>(code) << count_;
        count_ += count;
        while (count_ >= 8) {
            bytes_.push_back(static_cast<std::byte>(bits_ & 0xff));
            bits_ >>= 8;
            count_ -= 8;
        }
    }
    std::vector<std::byte> finish() {
        if (count_ > 0) bytes_.push_back(static_cast<std::byte>(bits_ & 0xff));
        return std::move(bytes_);
    }
private:
    std::uint32_t bits_{};
    int count_{};
    std::vector<std::byte> bytes_;
};
}

std::vector<std::byte> gifLzwEncode(std::span<const std::uint8_t> pixels,
                                    std::uint8_t minimumCodeSize) {
    minimumCodeSize = std::max<std::uint8_t>(2, minimumCodeSize);
    const auto clear = static_cast<std::uint16_t>(1U << minimumCodeSize);
    const auto end = static_cast<std::uint16_t>(clear + 1);
    auto next = static_cast<std::uint16_t>(end + 1);
    int codeSize = minimumCodeSize + 1;
    std::unordered_map<std::uint32_t, std::uint16_t> dictionary;
    BitWriter writer;
    writer.write(clear, codeSize);
    if (!pixels.empty()) {
        std::uint16_t prefix = pixels.front();
        for (const auto suffix : pixels.subspan(1)) {
            const auto key = (static_cast<std::uint32_t>(prefix) << 8) | suffix;
            if (const auto found = dictionary.find(key); found != dictionary.end()) {
                prefix = found->second;
                continue;
            }
            writer.write(prefix, codeSize);
            if (next < 4096) {
                dictionary.emplace(key, next++);
                if (next == (1U << codeSize) + 1 && codeSize < 12) ++codeSize;
            } else {
                writer.write(clear, codeSize);
                dictionary.clear();
                next = end + 1;
                codeSize = minimumCodeSize + 1;
            }
            prefix = suffix;
        }
        writer.write(prefix, codeSize);
    }
    writer.write(end, codeSize);
    auto compressed = writer.finish();
    std::vector<std::byte> blocks;
    for (std::size_t offset = 0; offset < compressed.size();) {
        const auto count = std::min<std::size_t>(255, compressed.size() - offset);
        blocks.push_back(static_cast<std::byte>(count));
        blocks.insert(blocks.end(), compressed.begin() + offset,
                      compressed.begin() + offset + count);
        offset += count;
    }
    blocks.push_back(std::byte{});
    return blocks;
}

}  // namespace pnclip
