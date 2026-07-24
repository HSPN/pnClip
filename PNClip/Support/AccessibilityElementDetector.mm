#import "AccessibilityElementDetector.h"
#import <ApplicationServices/ApplicationServices.h>

static BOOL CopyElementFrame(AXUIElementRef element, CGRect *frame) {
    CFTypeRef frameValue = nullptr;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXFrame"), &frameValue) == kAXErrorSuccess &&
        frameValue && CFGetTypeID(frameValue) == AXValueGetTypeID()) {
        BOOL valid = AXValueGetValue((AXValueRef)frameValue,
                                     (AXValueType)kAXValueCGRectType, frame);
        CFRelease(frameValue);
        if (valid) return YES;
    } else if (frameValue) {
        CFRelease(frameValue);
    }

    CFTypeRef positionValue = nullptr;
    CFTypeRef sizeValue = nullptr;
    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL valid = AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &positionValue) == kAXErrorSuccess &&
                 AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess &&
                 positionValue && sizeValue &&
                 AXValueGetValue((AXValueRef)positionValue, (AXValueType)kAXValueCGPointType, &position) &&
                 AXValueGetValue((AXValueRef)sizeValue, (AXValueType)kAXValueCGSizeType, &size);
    if (positionValue) CFRelease(positionValue);
    if (sizeValue) CFRelease(sizeValue);
    if (valid) *frame = CGRectMake(position.x, position.y, size.width, size.height);
    return valid;
}

@implementation AccessibilityElementDetector
- (NSRect)componentFrameAtScreenPoint:(NSPoint)screenPoint
                          belowWindow:(NSWindow *)overlayWindow
                  excludingProcessID:(pid_t)excludedProcessID {
    if (!overlayWindow) return NSZeroRect;
    CGFloat primaryTop = NSMaxY(NSScreen.screens.firstObject.frame);
    CGPoint quartzPoint = CGPointMake(screenPoint.x, primaryTop - screenPoint.y);
    CFArrayRef infoRef = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenBelowWindow,
                                                    (CGWindowID)overlayWindow.windowNumber);
    NSArray *windowInfo = CFBridgingRelease(infoRef);
    pid_t targetPID = 0;
    CGRect targetWindowFrame = CGRectZero;
    for (NSDictionary *info in windowInfo) {
        if ([info[(id)kCGWindowLayer] integerValue] != 0) continue;
        pid_t ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
        if (ownerPID == excludedProcessID) continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds)) continue;
        if (CGRectContainsPoint(bounds, quartzPoint)) {
            targetPID = ownerPID;
            targetWindowFrame = bounds;
            break;
        }
    }
    if (targetPID == 0) return NSZeroRect;

    CGRect componentFrame = CGRectZero;
    AXUIElementRef application = AXUIElementCreateApplication(targetPID);
    AXUIElementRef element = nullptr;
    AXError error = AXUIElementCopyElementAtPosition(application, quartzPoint.x,
                                                      quartzPoint.y, &element);
    if (error == kAXErrorSuccess && element) {
        CopyElementFrame(element, &componentFrame);
        CFRelease(element);
    }
    CFRelease(application);
    if (CGRectIsEmpty(componentFrame) || !CGRectContainsPoint(componentFrame, quartzPoint)) {
        componentFrame = targetWindowFrame;
    }
    return NSMakeRect(CGRectGetMinX(componentFrame),
                      primaryTop - CGRectGetMaxY(componentFrame),
                      CGRectGetWidth(componentFrame), CGRectGetHeight(componentFrame));
}
@end
