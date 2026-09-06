#import <AppKit/AppKit.h>

@interface SelectionView : NSView
@property(nonatomic, copy) void (^completion)(NSRect screenRect);
@property(nonatomic, copy) void (^componentCompletion)(NSRect componentScreenRect,
                                                       NSPoint detectionScreenPoint);
@property(nonatomic, copy) void (^cancellation)(void);
@property(nonatomic, copy) NSRect (^componentFrameProvider)(NSPoint screenPoint);
@end
