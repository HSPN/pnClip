#import <AppKit/AppKit.h>

@interface PNClipSelectionTarget : NSObject
@property(nonatomic) CGWindowID windowID;
@property(nonatomic) NSRect selectedFrame;
@property(nonatomic) CGRect windowBounds;
@property(nonatomic) pid_t processID;
@property(nonatomic, strong) id accessibilityWindow;
@end

@interface AccessibilityElementDetector : NSObject
- (PNClipSelectionTarget *)selectionTargetAtScreenPoint:(NSPoint)screenPoint
                                             belowWindow:(NSWindow *)overlayWindow
                                     excludingProcessID:(pid_t)excludedProcessID;
- (NSRect)componentFrameAtScreenPoint:(NSPoint)screenPoint
                          belowWindow:(NSWindow *)overlayWindow
                  excludingProcessID:(pid_t)excludedProcessID;
@end
