#import "GIFLZWEncoder.h"
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace {
class BitWriter {
public:
    void write(uint16_t code, int bitCount) {
        bits_ |= (uint32_t)code << bitCount_;
        bitCount_ += bitCount;
        while (bitCount_ >= 8) {
            bytes_.push_back((uint8_t)(bits_ & 0xff));
            bits_ >>= 8;
            bitCount_ -= 8;
        }
    }
    std::vector<uint8_t> finish() {
        if (bitCount_ > 0) bytes_.push_back((uint8_t)(bits_ & 0xff));
        return std::move(bytes_);
    }
private:
    uint32_t bits_ = 0;
    int bitCount_ = 0;
    std::vector<uint8_t> bytes_;
};
}

@implementation GIFLZWEncoder
+ (NSData *)encodeIndexedPixels:(NSData *)pixelData minimumCodeSize:(uint8_t)minimumCodeSize {
    minimumCodeSize = MAX((uint8_t)2, minimumCodeSize);
    const uint8_t *pixels = (const uint8_t *)pixelData.bytes;
    size_t length = pixelData.length;
    uint16_t clearCode = (uint16_t)(1 << minimumCodeSize);
    uint16_t endCode = clearCode + 1;
    uint16_t nextCode = endCode + 1;
    int codeSize = minimumCodeSize + 1;
    std::unordered_map<uint32_t, uint16_t> dictionary;
    dictionary.reserve(4096);
    BitWriter writer;
    writer.write(clearCode, codeSize);
    if (length == 0) {
        writer.write(endCode, codeSize);
    } else {
        uint16_t prefix = pixels[0];
        for (size_t i = 1; i < length; i++) {
            uint8_t suffix = pixels[i];
            uint32_t key = ((uint32_t)prefix << 8) | suffix;
            auto found = dictionary.find(key);
            if (found != dictionary.end()) {
                prefix = found->second;
                continue;
            }
            writer.write(prefix, codeSize);
            if (nextCode < 4096) {
                dictionary.emplace(key, nextCode++);
                // The decoder creates an entry only after reading the next
                // code, so its table trails the encoder by one entry.
                if (nextCode == (1 << codeSize) + 1 && codeSize < 12) codeSize++;
            } else {
                writer.write(clearCode, codeSize);
                dictionary.clear();
                nextCode = endCode + 1;
                codeSize = minimumCodeSize + 1;
            }
            prefix = suffix;
        }
        writer.write(prefix, codeSize);
        writer.write(endCode, codeSize);
    }

    std::vector<uint8_t> compressed = writer.finish();
    NSMutableData *blocks = [NSMutableData data];
    size_t offset = 0;
    while (offset < compressed.size()) {
        uint8_t blockSize = (uint8_t)std::min<size_t>(255, compressed.size() - offset);
        [blocks appendBytes:&blockSize length:1];
        [blocks appendBytes:compressed.data() + offset length:blockSize];
        offset += blockSize;
    }
    uint8_t terminator = 0;
    [blocks appendBytes:&terminator length:1];
    return blocks;
}
@end
