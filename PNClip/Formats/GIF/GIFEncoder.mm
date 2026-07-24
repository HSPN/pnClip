#import "GIFEncoder.h"
#import "GIFColorQuantizer.h"
#import "GIFDitherer.h"
#import "GIFLZWEncoder.h"
#include <cmath>

namespace {
static NSString *const GIFEncoderErrorDomain = @"PNClip.GIFEncoder";

static void AppendByte(NSMutableData *data, uint8_t value) {
    [data appendBytes:&value length:1];
}

static void AppendUInt16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[] = {(uint8_t)(value & 0xff), (uint8_t)(value >> 8)};
    [data appendBytes:bytes length:2];
}

static NSMutableData *CopyRGBABytes(CGImageRef image) {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    size_t bytesPerRow = width * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bytesPerRow * height];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8,
                                                  bytesPerRow, colorSpace,
                                                  kCGImageAlphaPremultipliedLast |
                                                  kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) return nil;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    return pixels;
}

static NSError *GIFError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:GIFEncoderErrorDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}
}

@implementation GIFEncoder
- (BOOL)encodeFrames:(NSArray *)frames
      frameDurations:(NSArray<NSNumber *> *)frameDurations
               toURL:(NSURL *)destinationURL
               error:(NSError **)error {
    if (frames.count == 0 || frameDurations.count != frames.count) {
        if (error) *error = GIFError(1, @"인코딩할 프레임이 없습니다.");
        return NO;
    }
    CGImageRef first = (__bridge CGImageRef)frames.firstObject;
    size_t width = CGImageGetWidth(first);
    size_t height = CGImageGetHeight(first);
    if (!width || !height || width > UINT16_MAX || height > UINT16_MAX) {
        if (error) *error = GIFError(2, @"GIF가 지원하지 않는 이미지 크기입니다.");
        return NO;
    }
    for (id frameObject in frames) {
        CGImageRef frame = (__bridge CGImageRef)frameObject;
        if (CGImageGetWidth(frame) != width || CGImageGetHeight(frame) != height) {
            if (error) *error = GIFError(3, @"모든 GIF 프레임의 크기가 같아야 합니다.");
            return NO;
        }
    }

    GIFColorQuantizer *quantizer = [[GIFColorQuantizer alloc] init];
    double totalPixels = (double)width * height * frames.count;
    size_t sampleStep = (size_t)MAX(1.0, ceil(sqrt(totalPixels / 1500000.0)));
    for (id frameObject in frames) {
        CGImageRef frame = (__bridge CGImageRef)frameObject;
        @autoreleasepool {
            NSData *rgba = CopyRGBABytes(frame);
            if (!rgba) {
                if (error) *error = GIFError(4, @"프레임 픽셀을 읽을 수 없습니다.");
                return NO;
            }
            [quantizer addRGBABytes:(const uint8_t *)rgba.bytes width:width height:height
                        bytesPerRow:width * 4 sampleStep:sampleStep];
        }
    }
    NSData *palette = [quantizer makePaletteWithColorCount:256];
    GIFDitherer *ditherer = [[GIFDitherer alloc] initWithPalette:palette];

    NSMutableData *gif = [NSMutableData data];
    [gif appendBytes:"GIF89a" length:6];
    AppendUInt16(gif, (uint16_t)width);
    AppendUInt16(gif, (uint16_t)height);
    AppendByte(gif, 0xF7); // global 256-color table, 8-bit color resolution
    AppendByte(gif, 0);
    AppendByte(gif, 0);
    [gif appendData:palette];

    const uint8_t loopExtension[] = {
        0x21, 0xFF, 0x0B, 'N','E','T','S','C','A','P','E','2','.','0',
        0x03, 0x01, 0x00, 0x00, 0x00};
    [gif appendBytes:loopExtension length:sizeof(loopExtension)];

    NSInteger previousTick = 0;
    NSTimeInterval elapsed = 0;
    for (NSUInteger index = 0; index < frames.count; index++) {
        @autoreleasepool {
            CGImageRef frame = (__bridge CGImageRef)frames[index];
            NSData *rgba = CopyRGBABytes(frame);
            if (!rgba) {
                if (error) *error = GIFError(5, @"GIF 프레임 변환에 실패했습니다.");
                return NO;
            }
            NSData *indexed = [ditherer indexedPixelsForRGBABytes:(const uint8_t *)rgba.bytes
                width:width height:height bytesPerRow:width * 4];
            elapsed += MAX(0.01, frameDurations[index].doubleValue);
            NSInteger tick = lround(elapsed * 100.0);
            uint16_t delay = (uint16_t)MAX(1, tick - previousTick);
            previousTick = tick;

            const uint8_t gcePrefix[] = {0x21, 0xF9, 0x04, 0x00};
            [gif appendBytes:gcePrefix length:sizeof(gcePrefix)];
            AppendUInt16(gif, delay);
            AppendByte(gif, 0);
            AppendByte(gif, 0);
            AppendByte(gif, 0x2C);
            AppendUInt16(gif, 0); AppendUInt16(gif, 0);
            AppendUInt16(gif, (uint16_t)width); AppendUInt16(gif, (uint16_t)height);
            AppendByte(gif, 0);
            AppendByte(gif, 8);
            [gif appendData:[GIFLZWEncoder encodeIndexedPixels:indexed minimumCodeSize:8]];
        }
    }
    AppendByte(gif, 0x3B);
    NSError *writeError = nil;
    BOOL success = [gif writeToURL:destinationURL options:NSDataWritingAtomic error:&writeError];
    if (!success && error) *error = writeError ?: GIFError(6, @"GIF 파일을 저장하지 못했습니다.");
    return success;
}
@end
