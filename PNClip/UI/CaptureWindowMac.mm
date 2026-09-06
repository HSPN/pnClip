#import "CaptureWindowMac.h"

@implementation CaptureWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end
