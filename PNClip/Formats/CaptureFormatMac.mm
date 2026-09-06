#import "CaptureFormatMac.h"
#import "GIF/GIFEncoderMac.h"
#import "WebP/WebPEncoderMac.h"
#include "../Core/CaptureTypes.hpp"

NSString *PNClipStillImageExtension(PNClipCaptureFormat format) {
    const auto value = pnclip::stillImageExtension(
        format == PNClipCaptureFormatWebP ? pnclip::CaptureFormat::webP
                                         : pnclip::CaptureFormat::pngGif);
    return [NSString stringWithUTF8String:value.data()];
}

NSString *PNClipAnimatedImageExtension(PNClipCaptureFormat format) {
    const auto value = pnclip::animatedImageExtension(
        format == PNClipCaptureFormatWebP ? pnclip::CaptureFormat::webP
                                         : pnclip::CaptureFormat::pngGif);
    return [NSString stringWithUTF8String:value.data()];
}

id<AnimatedImageEncoder> PNClipCreateAnimatedImageEncoder(PNClipCaptureFormat format) {
    return format == PNClipCaptureFormatWebP
        ? [[WebPEncoder alloc] init]
        : [[GIFEncoder alloc] init];
}

NSData *PNClipEncodeStillImage(CGImageRef image, PNClipCaptureFormat format, NSError **error) {
    if (format == PNClipCaptureFormatPNGGIF) {
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
        NSData *data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!data && error) {
            *error = [NSError errorWithDomain:@"PNClip.CaptureFormat" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"PNG 이미지 변환에 실패했습니다."}];
        }
        return data;
    }

    WebPEncoder *encoder = [[WebPEncoder alloc] init];
    NSURL *temporaryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    BOOL success = [encoder encodeFrames:@[(__bridge id)image]
                          frameDurations:@[@1.0]
                                   toURL:temporaryURL
                                   error:error];
    NSData *data = success ? [NSData dataWithContentsOfURL:temporaryURL] : nil;
    [NSFileManager.defaultManager removeItemAtURL:temporaryURL error:nil];
    return data;
}
