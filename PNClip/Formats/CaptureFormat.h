#import <AppKit/AppKit.h>
#import "AnimatedImageEncoder.h"

typedef NS_ENUM(NSInteger, PNClipCaptureFormat) {
    PNClipCaptureFormatPNGGIF = 0,
    PNClipCaptureFormatWebP = 1,
};

FOUNDATION_EXPORT NSString *PNClipStillImageExtension(PNClipCaptureFormat format);
FOUNDATION_EXPORT NSString *PNClipAnimatedImageExtension(PNClipCaptureFormat format);
FOUNDATION_EXPORT id<AnimatedImageEncoder> PNClipCreateAnimatedImageEncoder(PNClipCaptureFormat format);
FOUNDATION_EXPORT NSData *PNClipEncodeStillImage(CGImageRef image,
                                                  PNClipCaptureFormat format,
                                                  NSError **error);
