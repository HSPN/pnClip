#import <AppKit/AppKit.h>

@interface CaptureView : NSView
@property(nonatomic) CGFloat interiorTransparency;
@property(nonatomic, getter=isRecordingActive) BOOL recordingActive;
@property(nonatomic, getter=isCaptureFlashActive) BOOL captureFlashActive;
@end
