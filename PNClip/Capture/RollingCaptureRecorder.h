#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface RollingCaptureRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, readonly, getter=isCapturing) BOOL capturing;
- (instancetype)initWithDestinationFolder:(NSURL *)destinationFolder;
- (void)startWithFilter:(SCContentFilter *)filter
          configuration:(SCStreamConfiguration *)configuration
             completion:(void (^)(NSError *error))completion;
- (void)saveRecentGIFWithDuration:(NSTimeInterval)duration
                       completion:(void (^)(NSURL *fileURL, NSError *error))completion;
- (unsigned long long)estimatedGIFSizeForDuration:(NSTimeInterval)duration;
- (void)stop;
@end
