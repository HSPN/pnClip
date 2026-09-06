#import "GIFEncoderMac.h"
#include "../../Core/GifEncoder.hpp"

static pnclip::PixelBuffer GIFPixelBufferFromCGImage(CGImageRef image) {
    pnclip::PixelBuffer result;
    result.width = (uint32_t)CGImageGetWidth(image);
    result.height = (uint32_t)CGImageGetHeight(image);
    result.stride = result.width * 4;
    result.format = pnclip::PixelFormat::rgba8;
    result.bytes.resize((size_t)result.stride * result.height);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(result.bytes.data(), result.width, result.height,
        8, result.stride, colorSpace,
        (CGBitmapInfo)(kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(colorSpace);
    if (!context) return {};
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, result.width, result.height), image);
    CGContextRelease(context);
    return result;
}

@implementation GIFEncoder
- (BOOL)encodeFrames:(NSArray *)frames
      frameDurations:(NSArray<NSNumber *> *)frameDurations
               toURL:(NSURL *)destinationURL
               error:(NSError **)error {
    std::vector<pnclip::PixelBuffer> buffers;
    std::vector<std::chrono::milliseconds> durations;
    for (NSUInteger index = 0; index < frames.count; ++index) {
        buffers.push_back(GIFPixelBufferFromCGImage((__bridge CGImageRef)frames[index]));
        durations.emplace_back((long long)llround(frameDurations[index].doubleValue * 1000.0));
    }
    const auto result = pnclip::GifEncoder{}.encode(buffers, durations);
    if (!result) {
        if (error) *error = [NSError errorWithDomain:@"PNClip.GIFEncoder" code:result.error.code
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithUTF8String:result.error.message.c_str()]}];
        return NO;
    }
    NSData *data = [NSData dataWithBytes:result.data.data() length:result.data.size()];
    return [data writeToURL:destinationURL options:NSDataWritingAtomic error:error];
}
@end
