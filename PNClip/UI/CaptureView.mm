#import "CaptureView.h"

static constexpr CGFloat kBorderWidth = 4.0;
static constexpr CGFloat kEdgeResizeHitWidth = 12.0;
static constexpr CGFloat kCornerResizeHitSize = 22.0;
static constexpr CGFloat kMinimumWindowWidth = 160.0;
static constexpr CGFloat kMinimumWindowHeight = 100.0;

typedef NS_OPTIONS(NSUInteger, ResizeEdge) {
    ResizeEdgeNone   = 0,
    ResizeEdgeLeft   = 1 << 0,
    ResizeEdgeRight  = 1 << 1,
    ResizeEdgeBottom = 1 << 2,
    ResizeEdgeTop    = 1 << 3,
};

static NSCursor *CursorForResizeEdge(ResizeEdge edge) {
    if (@available(macOS 15.0, *)) {
        NSCursorFrameResizePosition position;
        switch (edge) {
            case ResizeEdgeTop | ResizeEdgeLeft: position = NSCursorFrameResizePositionTopLeft; break;
            case ResizeEdgeTop | ResizeEdgeRight: position = NSCursorFrameResizePositionTopRight; break;
            case ResizeEdgeBottom | ResizeEdgeLeft: position = NSCursorFrameResizePositionBottomLeft; break;
            case ResizeEdgeBottom | ResizeEdgeRight: position = NSCursorFrameResizePositionBottomRight; break;
            case ResizeEdgeLeft: position = NSCursorFrameResizePositionLeft; break;
            case ResizeEdgeRight: position = NSCursorFrameResizePositionRight; break;
            case ResizeEdgeTop: position = NSCursorFrameResizePositionTop; break;
            default: position = NSCursorFrameResizePositionBottom; break;
        }
        return [NSCursor frameResizeCursorFromPosition:position
                                          inDirections:NSCursorFrameResizeDirectionsAll];
    }
    BOOL isCorner = (edge & (ResizeEdgeLeft | ResizeEdgeRight)) &&
                    (edge & (ResizeEdgeTop | ResizeEdgeBottom));
    if (isCorner) return NSCursor.crosshairCursor;
    return (edge & (ResizeEdgeLeft | ResizeEdgeRight))
        ? NSCursor.resizeLeftRightCursor
        : NSCursor.resizeUpDownCursor;
}

@implementation CaptureView {
    ResizeEdge _resizeEdge;
    NSPoint _resizeStartPoint;
    NSRect _resizeStartFrame;
    BOOL _recordingActive;
    BOOL _rollingRecordingActive;
    BOOL _captureFlashActive;
}

@synthesize recordingActive = _recordingActive;
@synthesize rollingRecordingActive = _rollingRecordingActive;
@synthesize captureFlashActive = _captureFlashActive;

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) _interiorTransparency = 80.0;
    return self;
}

- (BOOL)isOpaque { return NO; }

- (BOOL)isWindowGeometryLocked {
    return self.isRecordingActive || self.isRollingRecordingActive;
}

- (void)recordingStateDidChange {
    if (self.isWindowGeometryLocked) _resizeEdge = ResizeEdgeNone;
    [self.window invalidateCursorRectsForView:self];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect interiorRect = NSInsetRect(self.bounds, kBorderWidth, kBorderWidth);
    CGFloat opacity = 1.0 - self.interiorTransparency / 100.0;
    [[NSColor colorWithCalibratedWhite:0.0 alpha:opacity] setFill];
    NSRectFill(interiorRect);

    NSBezierPath *border = [NSBezierPath bezierPathWithRect:
        NSInsetRect(self.bounds, kBorderWidth / 2.0, kBorderWidth / 2.0)];
    border.lineWidth = kBorderWidth;
    NSColor *borderColor = self.isRollingRecordingActive
        ? [NSColor colorWithCalibratedRed:0.94 green:0.12 blue:0.12 alpha:1.0]
        : ((self.isRecordingActive || self.isCaptureFlashActive)
            ? [NSColor colorWithCalibratedRed:1.0 green:0.48 blue:0.08 alpha:1.0]
            : [NSColor colorWithCalibratedRed:0.16 green:0.64 blue:1.0 alpha:1.0]);
    [borderColor setStroke];
    [border stroke];
}

- (void)setRecordingActive:(BOOL)value {
    if (_recordingActive == value) return;
    _recordingActive = value;
    [self recordingStateDidChange];
}

- (void)setCaptureFlashActive:(BOOL)value {
    if (_captureFlashActive == value) return;
    _captureFlashActive = value;
    [self setNeedsDisplay:YES];
}

- (void)setRollingRecordingActive:(BOOL)value {
    if (_rollingRecordingActive == value) return;
    _rollingRecordingActive = value;
    [self recordingStateDidChange];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)mouseDown:(NSEvent *)event {
    [self.window makeKeyAndOrderFront:nil];
    if (self.isWindowGeometryLocked) {
        _resizeEdge = ResizeEdgeNone;
        return;
    }
    _resizeEdge = [self resizeEdgeAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (_resizeEdge == ResizeEdgeNone) {
        [self.window performWindowDragWithEvent:event];
        return;
    }
    _resizeStartPoint = NSEvent.mouseLocation;
    _resizeStartFrame = self.window.frame;
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.isWindowGeometryLocked) return;
    if (_resizeEdge == ResizeEdgeNone) return;
    NSPoint currentPoint = NSEvent.mouseLocation;
    CGFloat dx = currentPoint.x - _resizeStartPoint.x;
    CGFloat dy = currentPoint.y - _resizeStartPoint.y;
    NSRect frame = _resizeStartFrame;
    if (_resizeEdge & ResizeEdgeLeft) {
        CGFloat width = MAX(kMinimumWindowWidth, NSWidth(_resizeStartFrame) - dx);
        frame.origin.x = NSMaxX(_resizeStartFrame) - width;
        frame.size.width = width;
    } else if (_resizeEdge & ResizeEdgeRight) {
        frame.size.width = MAX(kMinimumWindowWidth, NSWidth(_resizeStartFrame) + dx);
    }
    if (_resizeEdge & ResizeEdgeBottom) {
        CGFloat height = MAX(kMinimumWindowHeight, NSHeight(_resizeStartFrame) - dy);
        frame.origin.y = NSMaxY(_resizeStartFrame) - height;
        frame.size.height = height;
    } else if (_resizeEdge & ResizeEdgeTop) {
        frame.size.height = MAX(kMinimumWindowHeight, NSHeight(_resizeStartFrame) + dy);
    }
    [self.window setFrame:frame display:YES];
}

- (void)mouseUp:(NSEvent *)event { _resizeEdge = ResizeEdgeNone; }

- (ResizeEdge)resizeEdgeAtPoint:(NSPoint)point {
    NSRect bounds = self.bounds;
    CGFloat corner = MIN(kCornerResizeHitSize, MIN(NSWidth(bounds), NSHeight(bounds)) / 2.0);
    CGFloat edge = MIN(kEdgeResizeHitWidth, corner);
    if (NSPointInRect(point, NSMakeRect(0, 0, corner, corner))) return ResizeEdgeBottom | ResizeEdgeLeft;
    if (NSPointInRect(point, NSMakeRect(NSWidth(bounds)-corner, 0, corner, corner))) return ResizeEdgeBottom | ResizeEdgeRight;
    if (NSPointInRect(point, NSMakeRect(0, NSHeight(bounds)-corner, corner, corner))) return ResizeEdgeTop | ResizeEdgeLeft;
    if (NSPointInRect(point, NSMakeRect(NSWidth(bounds)-corner, NSHeight(bounds)-corner, corner, corner))) return ResizeEdgeTop | ResizeEdgeRight;
    CGFloat vertical = MAX(0.0, NSHeight(bounds) - 2.0 * corner);
    CGFloat horizontal = MAX(0.0, NSWidth(bounds) - 2.0 * corner);
    if (NSPointInRect(point, NSMakeRect(0, corner, edge, vertical))) return ResizeEdgeLeft;
    if (NSPointInRect(point, NSMakeRect(NSWidth(bounds)-edge, corner, edge, vertical))) return ResizeEdgeRight;
    if (NSPointInRect(point, NSMakeRect(corner, 0, horizontal, edge))) return ResizeEdgeBottom;
    if (NSPointInRect(point, NSMakeRect(corner, NSHeight(bounds)-edge, horizontal, edge))) return ResizeEdgeTop;
    return ResizeEdgeNone;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.isWindowGeometryLocked) return;
    NSRect bounds = self.bounds;
    CGFloat corner = MIN(kCornerResizeHitSize, MIN(NSWidth(bounds), NSHeight(bounds)) / 2.0);
    CGFloat edge = MIN(kEdgeResizeHitWidth, corner);
    CGFloat vertical = MAX(0.0, NSHeight(bounds) - 2.0 * corner);
    CGFloat horizontal = MAX(0.0, NSWidth(bounds) - 2.0 * corner);
    [self addCursorRect:NSMakeRect(0, 0, corner, corner) cursor:CursorForResizeEdge(ResizeEdgeBottom|ResizeEdgeLeft)];
    [self addCursorRect:NSMakeRect(NSWidth(bounds)-corner, 0, corner, corner) cursor:CursorForResizeEdge(ResizeEdgeBottom|ResizeEdgeRight)];
    [self addCursorRect:NSMakeRect(0, NSHeight(bounds)-corner, corner, corner) cursor:CursorForResizeEdge(ResizeEdgeTop|ResizeEdgeLeft)];
    [self addCursorRect:NSMakeRect(NSWidth(bounds)-corner, NSHeight(bounds)-corner, corner, corner) cursor:CursorForResizeEdge(ResizeEdgeTop|ResizeEdgeRight)];
    [self addCursorRect:NSMakeRect(0, corner, edge, vertical) cursor:CursorForResizeEdge(ResizeEdgeLeft)];
    [self addCursorRect:NSMakeRect(NSWidth(bounds)-edge, corner, edge, vertical) cursor:CursorForResizeEdge(ResizeEdgeRight)];
    [self addCursorRect:NSMakeRect(corner, 0, horizontal, edge) cursor:CursorForResizeEdge(ResizeEdgeBottom)];
    [self addCursorRect:NSMakeRect(corner, NSHeight(bounds)-edge, horizontal, edge) cursor:CursorForResizeEdge(ResizeEdgeTop)];
}
@end
