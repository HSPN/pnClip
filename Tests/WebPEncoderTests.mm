#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import "../PNClip/Formats/WebP/WebPEncoder.h"

static CGImageRef SolidImage(size_t width, size_t height, CGFloat red,
                             CGFloat green, CGFloat blue) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4,
                                                  colorSpace,
                                                  kCGImageAlphaPremultipliedLast |
                                                  kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    CGContextSetRGBFillColor(context, red, green, blue, 1.0);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

int main(void) {
    @autoreleasepool {
        NSMutableArray *frames = [NSMutableArray array];
        const CGFloat colors[][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
        for (const auto &color : colors) {
            CGImageRef image = SolidImage(64, 48, color[0], color[1], color[2]);
            [frames addObject:CFBridgingRelease(image)];
        }
        NSURL *url = [NSURL fileURLWithPath:@"/tmp/pnclip-webp-encoder-test.webp"];
        NSError *error = nil;
        WebPEncoder *encoder = [[WebPEncoder alloc] init];
        if (![encoder encodeFrames:frames frameDurations:@[@0.1, @0.2, @0.3]
                              toURL:url error:&error]) {
            NSLog(@"WebP encoder failed: %@", error);
            return 1;
        }
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data.length < 20 || memcmp(data.bytes, "RIFF", 4) != 0 ||
            memcmp((const uint8_t *)data.bytes + 8, "WEBP", 4) != 0 ||
            [data rangeOfData:[@"ANIM" dataUsingEncoding:NSASCIIStringEncoding]
                      options:0 range:NSMakeRange(0, data.length)].location == NSNotFound ||
            [data rangeOfData:[@"ANMF" dataUsingEncoding:NSASCIIStringEncoding]
                      options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) {
            NSLog(@"WebP output is not an animation container");
            return 2;
        }
        NSLog(@"WebP encoder test passed: %@ (%lu bytes)", url.path,
              (unsigned long)data.length);
    }
    return 0;
}
