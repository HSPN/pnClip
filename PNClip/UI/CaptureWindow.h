#import <AppKit/AppKit.h>

@interface CaptureWindow : NSWindow
@property(nonatomic) CGWindowID sourceWindowID;
@property(nonatomic) CGRect sourceWindowBounds;
@property(nonatomic) CGRect sourceRectInWindow;
@end
