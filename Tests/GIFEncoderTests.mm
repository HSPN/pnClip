#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../PNClip/Formats/GIF/GIFEncoder.h"

static CGImageRef MakeTestFrame(size_t width, size_t height, NSUInteger phase) {
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *bytes = (uint8_t *)pixels.mutableBytes;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t offset = (y * width + x) * 4;
            bytes[offset] = (uint8_t)((x * 255 / MAX((size_t)1, width - 1) + phase * 19) & 255);
            bytes[offset + 1] = (uint8_t)(y * 255 / MAX((size_t)1, height - 1));
            bytes[offset + 2] = (uint8_t)(((x + y + phase * 7) * 5) & 255);
            bytes[offset + 3] = 255;
        }
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, colorSpace,
                                     kCGImageAlphaLast | kCGBitmapByteOrder32Big,
                                     provider, nullptr, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    return image;
}

int main(void) {
    @autoreleasepool {
        NSMutableArray *frames = [NSMutableArray array];
        for (NSUInteger i = 0; i < 12; i++) {
            CGImageRef image = MakeTestFrame(96, 64, i);
            [frames addObject:CFBridgingRelease(image)];
        }
        NSURL *url = [NSURL fileURLWithPath:@"/tmp/pnclip-gif-encoder-test.gif"];
        NSError *error = nil;
        GIFEncoder *encoder = [[GIFEncoder alloc] init];
        NSMutableArray<NSNumber *> *durations = [NSMutableArray array];
        for (NSUInteger i = 0; i < frames.count; i++) [durations addObject:@(1.0 / 24.0)];
        if (![encoder encodeFrames:frames frameDurations:durations toURL:url error:&error]) {
            NSLog(@"encode failed: %@", error);
            return 1;
        }
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
        if (!source) return 2;
        NSDictionary *containerProperties = CFBridgingRelease(
            CGImageSourceCopyProperties(source, nullptr));
        NSDictionary *containerGIFProperties =
            containerProperties[(id)kCGImagePropertyGIFDictionary];
        NSNumber *loopCount = containerGIFProperties[(id)kCGImagePropertyGIFLoopCount];
        BOOL validType = [(__bridge NSString *)CGImageSourceGetType(source)
            isEqualToString:UTTypeGIF.identifier];
        size_t count = CGImageSourceGetCount(source);
        BOOL validSize = YES;
        NSTimeInterval decodedDuration = 0;
        for (size_t i = 0; i < count; i++) {
            CGImageRef decoded = CGImageSourceCreateImageAtIndex(source, i, nullptr);
            validSize = validSize && decoded && CGImageGetWidth(decoded) == 96 &&
                        CGImageGetHeight(decoded) == 64;
            if (decoded) CGImageRelease(decoded);
            NSDictionary *properties = CFBridgingRelease(
                CGImageSourceCopyPropertiesAtIndex(source, i, nullptr));
            NSDictionary *gifProperties = properties[(id)kCGImagePropertyGIFDictionary];
            decodedDuration += [gifProperties[(id)kCGImagePropertyGIFUnclampedDelayTime] doubleValue];
        }
        CFRelease(source);
        BOOL validDuration = fabs(decodedDuration - 0.5) < 0.02;
        NSData *encodedData = [NSData dataWithContentsOfURL:url];
        const uint8_t infiniteLoopExtension[] = {
            0x21, 0xFF, 0x0B, 'N','E','T','S','C','A','P','E','2','.','0',
            0x03, 0x01, 0x00, 0x00, 0x00};
        NSData *extensionData = [NSData dataWithBytes:infiniteLoopExtension
                                               length:sizeof(infiniteLoopExtension)];
        BOOL validLoop = loopCount && loopCount.integerValue == 0 &&
            [encodedData rangeOfData:extensionData options:0
                               range:NSMakeRange(0, encodedData.length)].location != NSNotFound;
        if (!validType || count != frames.count || !validSize || !validDuration || !validLoop) {
            NSLog(@"invalid GIF: type=%d count=%zu size=%d duration=%.3f loop=%@",
                  validType, count, validSize, decodedDuration, loopCount);
            return 3;
        }
        NSLog(@"GIF encoder test passed: %@ (%zu frames)", url.path, count);
    }
    return 0;
}
