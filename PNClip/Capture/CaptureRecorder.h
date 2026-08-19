#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "../Formats/CaptureFormat.h"

@interface CaptureRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, readonly) CGWindowID windowID;
@property(nonatomic, readonly, getter=isRecording) BOOL recording;
@property(nonatomic, copy) NSString *filenamePrefix;
- (instancetype)initWithWindowID:(CGWindowID)windowID
                destinationFolder:(NSURL *)destinationFolder
                   maximumDuration:(NSTimeInterval)maximumDuration
                     filenamePrefix:(NSString *)filenamePrefix
                       captureFormat:(PNClipCaptureFormat)captureFormat
                            cropRect:(CGRect)cropRect;
- (void)startWithFilter:(SCContentFilter *)filter
          configuration:(SCStreamConfiguration *)configuration
            stopHandler:(void (^)(void))stopHandler
             completion:(void (^)(NSURL *fileURL, NSError *error))completion;
- (void)stop;
- (unsigned long long)estimatedGIFSize;
@end
