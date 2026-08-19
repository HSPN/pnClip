#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "../Formats/CaptureFormat.h"

@interface RollingCaptureRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, readonly, getter=isCapturing) BOOL capturing;
@property(nonatomic, copy) NSString *filenamePrefix;
- (instancetype)initWithDestinationFolder:(NSURL *)destinationFolder
                            filenamePrefix:(NSString *)filenamePrefix
                              captureFormat:(PNClipCaptureFormat)captureFormat
                                   cropRect:(CGRect)cropRect;
- (void)startWithFilter:(SCContentFilter *)filter
          configuration:(SCStreamConfiguration *)configuration
             completion:(void (^)(NSError *error))completion;
- (void)saveRecentGIFWithDuration:(NSTimeInterval)duration
                       completion:(void (^)(NSURL *fileURL, NSError *error))completion;
- (unsigned long long)estimatedGIFSizeForDuration:(NSTimeInterval)duration;
- (void)stop;
@end
