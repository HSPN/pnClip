#import "SelectionView.h"
#import "../Support/PNClipConstants.h"

@implementation SelectionView {
    NSPoint _dragStart;
    NSPoint _dragCurrent;
    BOOL _dragging;
    NSRect _highlightedScreenRect;
    NSPoint _highlightedScreenPoint;
    NSTrackingArea *_trackingArea;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)isOpaque { return NO; }

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.01] setFill];
    NSRectFill(self.bounds);
    if (!_dragging) {
        if (!NSIsEmptyRect(_highlightedScreenRect)) {
            NSRect rect = [self.window convertRectFromScreen:_highlightedScreenRect];
            NSBezierPath *highlight = [NSBezierPath bezierPathWithRect:NSInsetRect(rect, 1.0, 1.0)];
            highlight.lineWidth = 2.0;
            [[NSColor colorWithCalibratedRed:1.0 green:0.72 blue:0.16 alpha:1.0] setStroke];
            [highlight stroke];
        }
        return;
    }
    NSRect selection = PNClipRectBetweenPoints(_dragStart, _dragCurrent);
    [[NSColor colorWithCalibratedRed:0.16 green:0.64 blue:1.0 alpha:0.18] setFill];
    NSRectFill(selection);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRect:NSInsetRect(selection, 1.0, 1.0)];
    outline.lineWidth = 2.0;
    [[NSColor colorWithCalibratedRed:0.16 green:0.64 blue:1.0 alpha:1.0] setStroke];
    [outline stroke];
}

- (void)updateHighlightForEvent:(NSEvent *)event {
    if (!self.componentFrameProvider) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _highlightedScreenPoint = [self.window convertPointToScreen:point];
    _highlightedScreenRect = self.componentFrameProvider(_highlightedScreenPoint);
    [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
    if (!_dragging) [self updateHighlightForEvent:event];
}

- (void)mouseDown:(NSEvent *)event {
    [self updateHighlightForEvent:event];
    _dragStart = [self convertPoint:event.locationInWindow fromView:nil];
    _dragCurrent = _dragStart;
    _dragging = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging) return;
    _dragCurrent = [self convertPoint:event.locationInWindow fromView:nil];
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (!_dragging) return;
    _dragCurrent = [self convertPoint:event.locationInWindow fromView:nil];
    _dragging = NO;
    NSRect selection = PNClipRectBetweenPoints(_dragStart, _dragCurrent);
    if (NSWidth(selection) < 20.0 || NSHeight(selection) < 20.0) {
        if (!NSIsEmptyRect(_highlightedScreenRect) && self.componentCompletion) {
            self.componentCompletion(_highlightedScreenRect, _highlightedScreenPoint);
        } else if (self.cancellation) {
            self.cancellation();
        }
        return;
    }
    if (self.completion) self.completion([self.window convertRectToScreen:selection]);
}

- (void)keyDown:(NSEvent *)event { if (self.cancellation) self.cancellation(); }
- (void)rightMouseDown:(NSEvent *)event { if (self.cancellation) self.cancellation(); }
- (void)otherMouseDown:(NSEvent *)event { if (self.cancellation) self.cancellation(); }
@end
