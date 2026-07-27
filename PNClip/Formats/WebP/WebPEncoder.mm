#import "WebPEncoder.h"
#include <webp/encode.h>
#include <webp/mux.h>
#include <cmath>

namespace {
static NSString *const WebPEncoderErrorDomain = @"PNClip.WebPEncoder";

static NSError *WebPError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:WebPEncoderErrorDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey: message}];
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
}

@implementation WebPEncoder
- (BOOL)encodeFrames:(NSArray *)frames
      frameDurations:(NSArray<NSNumber *> *)frameDurations
               toURL:(NSURL *)destinationURL
               error:(NSError **)error {
    if (frames.count == 0 || frames.count != frameDurations.count) {
        if (error) *error = WebPError(1, @"인코딩할 프레임이 없습니다.");
        return NO;
    }

    CGImageRef first = (__bridge CGImageRef)frames.firstObject;
    size_t width = CGImageGetWidth(first);
    size_t height = CGImageGetHeight(first);
    if (!width || !height || width > WEBP_MAX_DIMENSION || height > WEBP_MAX_DIMENSION) {
        if (error) *error = WebPError(2, @"WebP가 지원하지 않는 이미지 크기입니다.");
        return NO;
    }
    for (id frameObject in frames) {
        CGImageRef frame = (__bridge CGImageRef)frameObject;
        if (CGImageGetWidth(frame) != width || CGImageGetHeight(frame) != height) {
            if (error) *error = WebPError(3, @"모든 WebP 프레임의 크기가 같아야 합니다.");
            return NO;
        }
    }

    WebPAnimEncoderOptions options;
    if (!WebPAnimEncoderOptionsInit(&options)) {
        if (error) *error = WebPError(4, @"WebP 애니메이션 설정을 초기화하지 못했습니다.");
        return NO;
    }
    options.anim_params.loop_count = 0;
    options.minimize_size = 0;

    WebPAnimEncoder *encoder = WebPAnimEncoderNew((int)width, (int)height, &options);
    if (!encoder) {
        if (error) *error = WebPError(5, @"WebP 인코더를 만들지 못했습니다.");
        return NO;
    }

    WebPConfig config;
    if (!WebPConfigInit(&config)) {
        WebPAnimEncoderDelete(encoder);
        if (error) *error = WebPError(6, @"WebP 압축 설정을 초기화하지 못했습니다.");
        return NO;
    }
    config.lossless = 0;
    config.quality = 90.0f;
    config.method = 4;
    config.thread_level = 1;
    config.use_sharp_yuv = 1;

    NSInteger timestamp = 0;
    NSTimeInterval elapsed = 0;
    BOOL success = YES;
    for (NSUInteger index = 0; index < frames.count; index++) {
        @autoreleasepool {
            CGImageRef frame = (__bridge CGImageRef)frames[index];
            NSData *rgba = CopyRGBABytes(frame);
            WebPPicture picture;
            if (!rgba || !WebPPictureInit(&picture)) {
                success = NO;
            } else {
                picture.use_argb = 1;
                picture.width = (int)width;
                picture.height = (int)height;
                success = WebPPictureImportRGBA(&picture, (const uint8_t *)rgba.bytes,
                                                 (int)width * 4) &&
                          WebPAnimEncoderAdd(encoder, &picture, (int)timestamp, &config);
                WebPPictureFree(&picture);
            }
            if (!success) break;
            elapsed += MAX(0.001, frameDurations[index].doubleValue);
            timestamp = lround(elapsed * 1000.0);
        }
    }

    if (success) success = WebPAnimEncoderAdd(encoder, nullptr, (int)timestamp, nullptr);
    WebPData output;
    WebPDataInit(&output);
    if (success) success = WebPAnimEncoderAssemble(encoder, &output);
    NSString *encoderMessage = success ? nil
        : [NSString stringWithUTF8String:WebPAnimEncoderGetError(encoder) ?: "WebP encoding failed"];
    WebPAnimEncoderDelete(encoder);

    if (!success) {
        WebPDataClear(&output);
        if (error) *error = WebPError(7, encoderMessage ?: @"WebP 인코딩에 실패했습니다.");
        return NO;
    }
    NSData *data = [NSData dataWithBytes:output.bytes length:output.size];
    WebPDataClear(&output);
    NSError *writeError = nil;
    success = [data writeToURL:destinationURL options:NSDataWritingAtomic error:&writeError];
    if (!success && error) *error = writeError ?: WebPError(8, @"WebP 파일을 저장하지 못했습니다.");
    return success;
}
@end
