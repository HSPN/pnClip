#import <AppKit/AppKit.h>

@interface AccessibilityElementDetector : NSObject
- (NSRect)componentFrameAtScreenPoint:(NSPoint)screenPoint
                          belowWindow:(NSWindow *)overlayWindow
                  excludingProcessID:(pid_t)excludedProcessID;
@end
