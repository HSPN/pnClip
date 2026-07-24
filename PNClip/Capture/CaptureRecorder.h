#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface CaptureRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, readonly) CGWindowID windowID;
@property(nonatomic, readonly, getter=isRecording) BOOL recording;
- (instancetype)initWithWindowID:(CGWindowID)windowID
                destinationFolder:(NSURL *)destinationFolder
                   maximumDuration:(NSTimeInterval)maximumDuration;
- (void)startWithFilter:(SCContentFilter *)filter
          configuration:(SCStreamConfiguration *)configuration
            stopHandler:(void (^)(void))stopHandler
             completion:(void (^)(NSURL *fileURL, NSError *error))completion;
- (void)stop;
- (unsigned long long)estimatedGIFSize;
@end
