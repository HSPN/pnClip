#import "GIFLZWEncoderMac.h"
#include "../../Core/GifLzwEncoder.hpp"

@implementation GIFLZWEncoder
+ (NSData *)encodeIndexedPixels:(NSData *)pixelData minimumCodeSize:(uint8_t)minimumCodeSize {
    const auto pixels = std::span{static_cast<const uint8_t *>(pixelData.bytes),
                                  pixelData.length};
    const auto blocks = pnclip::gifLzwEncode(pixels, minimumCodeSize);
    return [NSData dataWithBytes:blocks.data() length:blocks.size()];
}
@end
