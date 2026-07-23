#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static constexpr CGFloat kBorderWidth = 4.0;
static constexpr CGFloat kResizeHitWidth = 9.0;
static constexpr NSInteger kRecordingFramesPerSecond = 24;
static constexpr NSTimeInterval kMaximumRecordingDuration = 10.0;
static constexpr NSTimeInterval kCaptureFlashDuration = 0.2;
static NSString *const kSaveFolderBookmarkKey = @"SaveFolderBookmark";
static NSString *const kErrorDomain = @"PNClip";

typedef NS_OPTIONS(NSUInteger, ResizeEdge) {
    ResizeEdgeNone   = 0,
    ResizeEdgeLeft   = 1 << 0,
    ResizeEdgeRight  = 1 << 1,
    ResizeEdgeBottom = 1 << 2,
    ResizeEdgeTop    = 1 << 3,
};

static NSRect RectBetweenPoints(NSPoint first, NSPoint second) {
    return NSMakeRect(MIN(first.x, second.x),
                      MIN(first.y, second.y),
                      fabs(second.x - first.x),
                      fabs(second.y - first.y));
}

static NSURL *TimestampedFileURL(NSURL *folder, NSString *prefix, NSString *extension) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    NSString *filename = [NSString stringWithFormat:@"%@ %@.%@",
                          prefix, [formatter stringFromDate:NSDate.date], extension];
    return [folder URLByAppendingPathComponent:filename];
}

static BOOL CopyAXElementFrame(AXUIElementRef element, CGRect *frame) {
    CFTypeRef frameValue = nullptr;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXFrame"), &frameValue) == kAXErrorSuccess &&
        frameValue && CFGetTypeID(frameValue) == AXValueGetTypeID()) {
        BOOL valid = AXValueGetValue((AXValueRef)frameValue, (AXValueType)kAXValueCGRectType, frame);
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

@interface CaptureView : NSView
@property(nonatomic) CGFloat interiorTransparency;
@property(nonatomic, getter=isRecordingActive) BOOL recordingActive;
@property(nonatomic, getter=isCaptureFlashActive) BOOL captureFlashActive;
@end

@interface CaptureWindow : NSWindow
@end

@interface SelectionWindow : NSWindow
@end

@interface SelectionView : NSView
@property(nonatomic, copy) void (^completion)(NSRect screenRect);
@property(nonatomic, copy) void (^cancellation)(void);
@property(nonatomic, copy) NSRect (^componentFrameProvider)(NSPoint screenPoint);
@end

@interface CaptureRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, readonly) CGWindowID windowID;
@property(nonatomic, readonly, getter=isRecording) BOOL recording;
- (instancetype)initWithWindowID:(CGWindowID)windowID;
- (instancetype)initWithWindowID:(CGWindowID)windowID
                destinationFolder:(NSURL *)destinationFolder;
- (void)startWithFilter:(SCContentFilter *)filter
          configuration:(SCStreamConfiguration *)configuration
            stopHandler:(void (^)(void))stopHandler
             completion:(void (^)(NSURL *fileURL, NSError *error))completion;
- (void)stop;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSMutableArray<NSWindow *> *windows;
@property(nonatomic, strong) NSSlider *transparencySlider;
@property(nonatomic, weak) NSWindow *selectedWindow;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) SelectionWindow *selectionWindow;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, CaptureRecorder *> *recorders;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *mousePassthroughWindowIDs;
@property(nonatomic, strong) NSNumber *globalRecordingWindowKey;
@property(nonatomic) CFMachPortRef recordingShortcutTap;
@property(nonatomic) CFRunLoopSourceRef recordingShortcutSource;
@property(nonatomic, strong) NSMenuItem *recordingMouseInputItem;
@property(nonatomic, strong) NSMenuItem *launchAtLoginItem;
@property(nonatomic) BOOL recordingMouseInputEnabled;
@property(nonatomic, strong) id globalMouseMonitor;
@property(nonatomic, strong) id localMouseMonitor;
@property(nonatomic, strong) NSTimer *mouseTrackingTimer;
@property(nonatomic, strong) NSURL *saveDirectoryURL;
@property(nonatomic, strong) NSURL *lastCreatedFileURL;
@property(nonatomic) BOOL accessingSecurityScopedDirectory;
- (void)newWindow:(id)sender;
- (void)createWindowWithFrame:(NSRect)frame;
- (void)closeCurrentWindow:(id)sender;
- (void)closeAllWindows:(id)sender;
- (void)statusItemClicked:(id)sender;
- (void)chooseSaveLocation:(id)sender;
- (void)openMostRecentCapture:(id)sender;
- (void)openSaveDirectory:(id)sender;
- (void)copyGIFAtURLToPasteboard:(NSURL *)fileURL;
- (NSWindow *)activeCaptureWindow;
- (BOOL)ensureScreenCaptureAccessForWindow:(NSWindow *)window;
- (void)loadContentFilterForScreen:(NSScreen *)screen
                        completion:(void (^)(SCContentFilter *filter, NSError *error))completion;
- (SCStreamConfiguration *)configurationForRect:(NSRect)rect
                                        onScreen:(NSScreen *)screen
                                  usesNativeScale:(BOOL)usesNativeScale;
- (void)stopMousePassthroughForWindow:(NSWindow *)window key:(NSNumber *)windowKey;
- (BOOL)installRecordingShortcutTapForWindow:(NSWindow *)window;
- (void)removeRecordingShortcutTap;
- (void)stopGlobalRecording;
- (void)setRecordingAppearance:(BOOL)recording forWindow:(NSWindow *)window;
- (void)flashCaptureBorderForWindow:(NSWindow *)window;
- (void)dismissSelectionWindow;
- (void)updateMousePassthrough;
- (NSRect)componentFrameAtScreenPoint:(NSPoint)screenPoint;
- (void)capture:(id)sender;
- (void)toggleRecording:(id)sender;
- (void)toggleRecordingMouseInput:(id)sender;
- (void)toggleLaunchAtLogin:(id)sender;
- (void)refreshLaunchAtLoginState;
- (void)transparencyChanged:(NSSlider *)sender;
- (void)saveCapturedImage:(CGImageRef)image;
- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message window:(NSWindow *)window;
@end

static CGEventRef RecordingShortcutCallback(CGEventTapProxy proxy,
                                            CGEventType type,
                                            CGEventRef event,
                                            void *userInfo) {
    (void)proxy;
    AppDelegate *delegate = (__bridge AppDelegate *)userInfo;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (delegate.recordingShortcutTap) {
            CGEventTapEnable(delegate.recordingShortcutTap, true);
        }
        return event;
    }
    if (type != kCGEventKeyDown || !delegate.globalRecordingWindowKey) return event;

    CGEventFlags flags = CGEventGetFlags(event);
    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    BOOL isCommandR = keyCode == 15 && (flags & kCGEventFlagMaskCommand) != 0 &&
                      (flags & (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate)) == 0;
    if (!isCommandR) return event;

    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate stopGlobalRecording];
    });
    return nullptr;
}

@implementation CaptureView
{
    ResizeEdge _resizeEdge;
    NSPoint _resizeStartPoint;
    NSRect _resizeStartFrame;
    BOOL _recordingActive;
    BOOL _captureFlashActive;
}

@synthesize recordingActive = _recordingActive;
@synthesize captureFlashActive = _captureFlashActive;

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _interiorTransparency = 80.0;
    }
    return self;
}

- (BOOL)isOpaque {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect interiorRect = NSInsetRect(self.bounds, kBorderWidth, kBorderWidth);
    CGFloat opacity = 1.0 - self.interiorTransparency / 100.0;
    [[NSColor colorWithCalibratedWhite:0.0 alpha:opacity] setFill];
    NSRectFill(interiorRect);

    NSRect borderRect = NSInsetRect(self.bounds, kBorderWidth / 2.0, kBorderWidth / 2.0);
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:borderRect];
    border.lineWidth = kBorderWidth;
    NSColor *borderColor = (self.isRecordingActive || self.isCaptureFlashActive)
        ? [NSColor colorWithCalibratedRed:1.0 green:0.48 blue:0.08 alpha:1.0]
        : [NSColor colorWithCalibratedRed:0.16 green:0.64 blue:1.0 alpha:1.0];
    [borderColor setStroke];
    [border stroke];
}

- (void)setRecordingActive:(BOOL)recordingActive {
    if (_recordingActive == recordingActive) return;
    _recordingActive = recordingActive;
    [self setNeedsDisplay:YES];
}

- (void)setCaptureFlashActive:(BOOL)captureFlashActive {
    if (_captureFlashActive == captureFlashActive) return;
    _captureFlashActive = captureFlashActive;
    [self setNeedsDisplay:YES];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeKeyAndOrderFront:nil];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _resizeEdge = [self resizeEdgeAtPoint:point];
    if (_resizeEdge == ResizeEdgeNone) {
        [self.window performWindowDragWithEvent:event];
        return;
    }

    _resizeStartPoint = NSEvent.mouseLocation;
    _resizeStartFrame = self.window.frame;
}

- (void)mouseDragged:(NSEvent *)event {
    if (_resizeEdge == ResizeEdgeNone) return;

    NSPoint currentPoint = NSEvent.mouseLocation;
    CGFloat dx = currentPoint.x - _resizeStartPoint.x;
    CGFloat dy = currentPoint.y - _resizeStartPoint.y;
    NSRect frame = _resizeStartFrame;
    NSSize minimumSize = NSMakeSize(160.0, 100.0);

    if (_resizeEdge & ResizeEdgeLeft) {
        CGFloat newWidth = MAX(minimumSize.width, NSWidth(_resizeStartFrame) - dx);
        frame.origin.x = NSMaxX(_resizeStartFrame) - newWidth;
        frame.size.width = newWidth;
    } else if (_resizeEdge & ResizeEdgeRight) {
        frame.size.width = MAX(minimumSize.width, NSWidth(_resizeStartFrame) + dx);
    }

    if (_resizeEdge & ResizeEdgeBottom) {
        CGFloat newHeight = MAX(minimumSize.height, NSHeight(_resizeStartFrame) - dy);
        frame.origin.y = NSMaxY(_resizeStartFrame) - newHeight;
        frame.size.height = newHeight;
    } else if (_resizeEdge & ResizeEdgeTop) {
        frame.size.height = MAX(minimumSize.height, NSHeight(_resizeStartFrame) + dy);
    }

    [self.window setFrame:frame display:YES];
}

- (void)mouseUp:(NSEvent *)event {
    _resizeEdge = ResizeEdgeNone;
}

- (ResizeEdge)resizeEdgeAtPoint:(NSPoint)point {
    ResizeEdge edge = ResizeEdgeNone;
    if (point.x <= kResizeHitWidth) edge |= ResizeEdgeLeft;
    if (point.x >= NSWidth(self.bounds) - kResizeHitWidth) edge |= ResizeEdgeRight;
    if (point.y <= kResizeHitWidth) edge |= ResizeEdgeBottom;
    if (point.y >= NSHeight(self.bounds) - kResizeHitWidth) edge |= ResizeEdgeTop;
    return edge;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    NSRect bounds = self.bounds;
    [self addCursorRect:NSMakeRect(0, kResizeHitWidth,
                                   kResizeHitWidth, NSHeight(bounds) - 2 * kResizeHitWidth)
                 cursor:NSCursor.resizeLeftRightCursor];
    [self addCursorRect:NSMakeRect(NSWidth(bounds) - kResizeHitWidth, kResizeHitWidth,
                                   kResizeHitWidth, NSHeight(bounds) - 2 * kResizeHitWidth)
                 cursor:NSCursor.resizeLeftRightCursor];
    [self addCursorRect:NSMakeRect(kResizeHitWidth, 0,
                                   NSWidth(bounds) - 2 * kResizeHitWidth, kResizeHitWidth)
                 cursor:NSCursor.resizeUpDownCursor];
    [self addCursorRect:NSMakeRect(kResizeHitWidth, NSHeight(bounds) - kResizeHitWidth,
                                   NSWidth(bounds) - 2 * kResizeHitWidth, kResizeHitWidth)
                 cursor:NSCursor.resizeUpDownCursor];
}

@end

@implementation CaptureWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

@end

@implementation SelectionWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

@end

@implementation SelectionView
{
    NSPoint _dragStart;
    NSPoint _dragCurrent;
    BOOL _dragging;
    NSRect _highlightedScreenRect;
    NSTrackingArea *_trackingArea;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (BOOL)isOpaque {
    return NO;
}

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
    // A fully clear window may be skipped by WindowServer hit testing.
    // This nearly invisible fill keeps the entire overlay mouse-active.
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.01] setFill];
    NSRectFill(self.bounds);
    if (!_dragging) {
        if (!NSIsEmptyRect(_highlightedScreenRect)) {
            NSRect highlightedRect = [self.window convertRectFromScreen:_highlightedScreenRect];
            NSBezierPath *highlight = [NSBezierPath bezierPathWithRect:NSInsetRect(highlightedRect, 1.0, 1.0)];
            highlight.lineWidth = 2.0;
            [[NSColor colorWithCalibratedRed:1.0 green:0.72 blue:0.16 alpha:1.0] setStroke];
            [highlight stroke];
        }
        return;
    }

    NSRect selection = RectBetweenPoints(_dragStart, _dragCurrent);
    [[NSColor colorWithCalibratedRed:0.16 green:0.64 blue:1.0 alpha:0.18] setFill];
    NSRectFill(selection);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRect:NSInsetRect(selection, 1.0, 1.0)];
    outline.lineWidth = 2.0;
    [[NSColor colorWithCalibratedRed:0.16 green:0.64 blue:1.0 alpha:1.0] setStroke];
    [outline stroke];
}

- (void)updateHighlightForEvent:(NSEvent *)event {
    if (!self.componentFrameProvider) return;
    NSPoint windowPoint = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint screenPoint = [self.window convertPointToScreen:windowPoint];
    _highlightedScreenRect = self.componentFrameProvider(screenPoint);
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
    NSRect selection = RectBetweenPoints(_dragStart, _dragCurrent);
    if (NSWidth(selection) < 20.0 || NSHeight(selection) < 20.0) {
        if (!NSIsEmptyRect(_highlightedScreenRect) && self.completion) {
            self.completion(_highlightedScreenRect);
        } else if (self.cancellation) {
            self.cancellation();
        }
        return;
    }
    NSRect screenRect = [self.window convertRectToScreen:selection];
    if (self.completion) self.completion(screenRect);
}

- (void)keyDown:(NSEvent *)event {
    if (self.cancellation) self.cancellation();
}

- (void)rightMouseDown:(NSEvent *)event {
    if (self.cancellation) self.cancellation();
}

- (void)otherMouseDown:(NSEvent *)event {
    if (self.cancellation) self.cancellation();
}

@end

@implementation CaptureRecorder
{
    SCStream *_stream;
    NSMutableArray *_frames;
    CIContext *_ciContext;
    dispatch_queue_t _captureQueue;
    void (^_completion)(NSURL *, NSError *);
    void (^_stopHandler)(void);
    BOOL _started;
    BOOL _stopRequested;
    BOOL _finishing;
    NSURL *_destinationFolder;
}

- (instancetype)initWithWindowID:(CGWindowID)windowID {
    return [self initWithWindowID:windowID destinationFolder:nil];
}

- (instancetype)initWithWindowID:(CGWindowID)windowID
                destinationFolder:(NSURL *)destinationFolder {
    self = [super init];
    if (self) {
        _windowID = windowID;
        _destinationFolder = destinationFolder;
        _frames = [NSMutableArray array];
        _ciContext = [CIContext contextWithOptions:nil];
        _captureQueue = dispatch_queue_create("com.example.PNClip.gif-capture", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isRecording {
    @synchronized (self) {
        return !_finishing;
    }
}

- (void)startWithFilter:(SCContentFilter *)filter
          configuration:(SCStreamConfiguration *)configuration
            stopHandler:(void (^)(void))stopHandler
             completion:(void (^)(NSURL *, NSError *))completion {
    _completion = [completion copy];
    _stopHandler = [stopHandler copy];
    _stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];

    NSError *outputError = nil;
    if (![_stream addStreamOutput:self
                             type:SCStreamOutputTypeScreen
             sampleHandlerQueue:_captureQueue
                            error:&outputError]) {
        [self finishWithURL:nil error:outputError];
        return;
    }

    __weak CaptureRecorder *weakSelf = self;
    [_stream startCaptureWithCompletionHandler:^(NSError *error) {
        CaptureRecorder *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            [strongSelf finishWithURL:nil error:error];
            return;
        }

        @synchronized (strongSelf) {
            strongSelf->_started = YES;
        }
        if (strongSelf->_stopRequested) {
            [strongSelf stopStream];
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kMaximumRecordingDuration * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf stop];
        });
    }];
}

- (void)stop {
    BOOL shouldStop = NO;
    @synchronized (self) {
        if (_stopRequested || _finishing) return;
        _stopRequested = YES;
        shouldStop = _started;
    }
    if (shouldStop) [self stopStream];
}

- (void)stopStream {
    __weak CaptureRecorder *weakSelf = self;
    [_stream stopCaptureWithCompletionHandler:^(NSError *error) {
        CaptureRecorder *strongSelf = weakSelf;
        if (!strongSelf) return;
        void (^stopHandler)(void) = strongSelf->_stopHandler;
        strongSelf->_stopHandler = nil;
        if (stopHandler) dispatch_async(dispatch_get_main_queue(), stopHandler);
        dispatch_async(strongSelf->_captureQueue, ^{
            if (error) {
                [strongSelf finishWithURL:nil error:error];
            } else {
                [strongSelf encodeGIF];
            }
        });
    }];
}

- (void)stream:(SCStream *)stream
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || _stopRequested) return;
    if (!CMSampleBufferIsValid(sampleBuffer)) return;

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGImageRef frame = [_ciContext createCGImage:ciImage fromRect:ciImage.extent];
    if (frame) {
        [_frames addObject:CFBridgingRelease(frame)];
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (!_stopRequested) {
        [self finishWithURL:nil error:error];
    }
}

- (void)encodeGIF {
    if (_frames.count == 0) {
        NSError *error = [NSError errorWithDomain:kErrorDomain
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"녹화된 프레임이 없습니다."}];
        [self finishWithURL:nil error:error];
        return;
    }

    NSURL *destinationFolder = _destinationFolder;
    if (!destinationFolder) {
        destinationFolder = [NSFileManager.defaultManager
            URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject;
    }
    NSURL *destination = TimestampedFileURL(destinationFolder, @"PNClip Recording", @"gif");

    CGImageDestinationRef gif = CGImageDestinationCreateWithURL((__bridge CFURLRef)destination,
                                                                (__bridge CFStringRef)UTTypeGIF.identifier,
                                                                _frames.count,
                                                                nullptr);
    if (!gif) {
        NSError *error = [NSError errorWithDomain:kErrorDomain
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey: @"GIF 파일을 만들 수 없습니다."}];
        [self finishWithURL:nil error:error];
        return;
    }

    NSDictionary *gifProperties = @{
        (id)kCGImagePropertyGIFDictionary: @{
            (id)kCGImagePropertyGIFLoopCount: @0
        }
    };
    CGImageDestinationSetProperties(gif, (__bridge CFDictionaryRef)gifProperties);
    NSUInteger frameIndex = 0;
    for (id frameObject in _frames) {
        // GIF stores delays in centiseconds. Five 40 ms frames followed by
        // one 50 ms frame averages exactly 24 frames per second.
        NSTimeInterval frameDelay = (frameIndex % 6 == 5) ? 0.05 : 0.04;
        NSDictionary *frameProperties = @{
            (id)kCGImagePropertyGIFDictionary: @{
                (id)kCGImagePropertyGIFDelayTime: @(frameDelay),
                (id)kCGImagePropertyGIFUnclampedDelayTime: @(frameDelay)
            }
        };
        CGImageDestinationAddImage(gif,
                                   (__bridge CGImageRef)frameObject,
                                   (__bridge CFDictionaryRef)frameProperties);
        frameIndex++;
    }

    BOOL succeeded = CGImageDestinationFinalize(gif);
    CFRelease(gif);
    if (!succeeded) {
        NSError *error = [NSError errorWithDomain:kErrorDomain
                                             code:3
                                         userInfo:@{NSLocalizedDescriptionKey: @"GIF 저장에 실패했습니다."}];
        [self finishWithURL:nil error:error];
        return;
    }
    [self finishWithURL:destination error:nil];
}

- (void)finishWithURL:(NSURL *)fileURL error:(NSError *)error {
    @synchronized (self) {
        if (_finishing) return;
        _finishing = YES;
    }
    _stream = nil;
    [_frames removeAllObjects];
    void (^stopHandler)(void) = _stopHandler;
    _stopHandler = nil;
    void (^completion)(NSURL *, NSError *) = _completion;
    _completion = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (stopHandler) stopHandler();
        if (completion) completion(fileURL, error);
    });
}

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.windows = [NSMutableArray array];
    self.recorders = [NSMutableDictionary dictionary];
    self.mousePassthroughWindowIDs = [NSMutableSet set];
    self.recordingMouseInputEnabled = NO;
    [self refreshLaunchAtLoginState];
    [self restoreSaveDirectory];

    NSEventMask mouseMask = NSEventMaskMouseMoved |
                            NSEventMaskLeftMouseDown |
                            NSEventMaskRightMouseDown |
                            NSEventMaskOtherMouseDown |
                            NSEventMaskLeftMouseDragged |
                            NSEventMaskRightMouseDragged |
                            NSEventMaskOtherMouseDragged;
    __weak AppDelegate *weakSelf = self;
    self.globalMouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mouseMask
                                                                    handler:^(NSEvent *event) {
        (void)event;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateMousePassthrough]; });
    }];
    self.localMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mouseMask
                                                                   handler:^NSEvent *(NSEvent *event) {
        [weakSelf updateMousePassthrough];
        return event;
    }];
    self.mouseTrackingTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                              repeats:YES
                                                                block:^(NSTimer *timer) {
        (void)timer;
        if (weakSelf.mousePassthroughWindowIDs.count > 0) {
            [weakSelf updateMousePassthrough];
        }
    }];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSStatusBarButton *statusButton = self.statusItem.button;
    statusButton.image = [NSImage imageWithSystemSymbolName:@"viewfinder"
                                   accessibilityDescription:@"PNClip 영역 선택"];
    if (!statusButton.image) {
        statusButton.title = @"PN";
    }
    statusButton.target = self;
    statusButton.action = @selector(statusItemClicked:);
    statusButton.toolTip = @"드래그해서 새 PNClip 창 만들기";

    [self newWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshLaunchAtLoginState {
    self.launchAtLoginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled
        ? NSControlStateValueOn
        : NSControlStateValueOff;
}

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL succeeded = service.status == SMAppServiceStatusEnabled
        ? [service unregisterAndReturnError:&error]
        : [service registerAndReturnError:&error];
    [self refreshLaunchAtLoginState];

    if (!succeeded) {
        [self showAlertWithTitle:@"자동 실행 설정 실패"
                         message:error.localizedDescription
                          window:self.selectedWindow];
    } else if (service.status == SMAppServiceStatusRequiresApproval) {
        [SMAppService openSystemSettingsLoginItems];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.globalMouseMonitor) [NSEvent removeMonitor:self.globalMouseMonitor];
    if (self.localMouseMonitor) [NSEvent removeMonitor:self.localMouseMonitor];
    [self.mouseTrackingTimer invalidate];
    [self removeRecordingShortcutTap];
    if (self.accessingSecurityScopedDirectory) {
        [self.saveDirectoryURL stopAccessingSecurityScopedResource];
    }
}

- (NSWindow *)activeCaptureWindow {
    NSWindow *window = self.selectedWindow ? self.selectedWindow : NSApp.keyWindow;
    return [window.contentView isKindOfClass:CaptureView.class] ? window : nil;
}

- (BOOL)ensureScreenCaptureAccessForWindow:(NSWindow *)window {
    if (CGPreflightScreenCaptureAccess()) return YES;

    CGRequestScreenCaptureAccess();
    [self showAlertWithTitle:@"화면 기록 권한 필요"
                     message:@"시스템 설정에서 PNClip의 화면 기록을 허용한 뒤 앱을 다시 실행해 주세요."
                      window:window];
    return NO;
}

- (void)loadContentFilterForScreen:(NSScreen *)screen
                        completion:(void (^)(SCContentFilter *, NSError *))completion {
    CGDirectDisplayID displayID = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    NSMutableSet<NSNumber *> *ownWindowIDs = [NSMutableSet setWithCapacity:self.windows.count];
    for (NSWindow *window in self.windows) {
        [ownWindowIDs addObject:@((CGWindowID)window.windowNumber)];
    }

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        SCDisplay *display = nil;
        for (SCDisplay *candidate in content.displays) {
            if (candidate.displayID == displayID) {
                display = candidate;
                break;
            }
        }
        if (!display) {
            NSError *displayError = [NSError errorWithDomain:kErrorDomain
                                                        code:4
                                                    userInfo:@{
                NSLocalizedDescriptionKey: @"캡처할 디스플레이를 찾을 수 없습니다."
            }];
            completion(nil, displayError);
            return;
        }

        NSMutableArray<SCWindow *> *excludedWindows = [NSMutableArray array];
        for (SCWindow *candidate in content.windows) {
            if ([ownWindowIDs containsObject:@(candidate.windowID)]) {
                [excludedWindows addObject:candidate];
            }
        }
        completion([[SCContentFilter alloc] initWithDisplay:display
                                           excludingWindows:excludedWindows], nil);
    }];
}

- (SCStreamConfiguration *)configurationForRect:(NSRect)rect
                                        onScreen:(NSScreen *)screen
                                  usesNativeScale:(BOOL)usesNativeScale {
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    configuration.sourceRect = CGRectMake(NSMinX(rect) - NSMinX(screen.frame),
                                           NSMaxY(screen.frame) - NSMaxY(rect),
                                           NSWidth(rect),
                                           NSHeight(rect));
    CGFloat scale = usesNativeScale ? screen.backingScaleFactor : 1.0;
    configuration.width = (size_t)round(NSWidth(rect) * scale);
    configuration.height = (size_t)round(NSHeight(rect) * scale);
    configuration.showsCursor = NO;
    return configuration;
}

- (void)stopMousePassthroughForWindow:(NSWindow *)window key:(NSNumber *)windowKey {
    [self.mousePassthroughWindowIDs removeObject:windowKey];
    window.ignoresMouseEvents = NO;
    if ([self.globalRecordingWindowKey isEqualToNumber:windowKey]) {
        self.globalRecordingWindowKey = nil;
        [self removeRecordingShortcutTap];
    }
}

- (BOOL)installRecordingShortcutTapForWindow:(NSWindow *)window {
    if (self.recordingShortcutTap) return YES;

    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    self.recordingShortcutTap = CGEventTapCreate(kCGSessionEventTap,
                                                  kCGHeadInsertEventTap,
                                                  kCGEventTapOptionDefault,
                                                  mask,
                                                  RecordingShortcutCallback,
                                                  (__bridge void *)self);
    if (!self.recordingShortcutTap) {
        [self showAlertWithTitle:@"접근성 권한 필요"
                         message:@"다른 앱을 사용하는 동안 Command-R로 녹화를 중지하려면 시스템 설정에서 PNClip의 접근성 권한을 허용해 주세요."
                          window:window];
        return NO;
    }

    self.recordingShortcutSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                                  self.recordingShortcutTap,
                                                                  0);
    CFRunLoopAddSource(CFRunLoopGetMain(), self.recordingShortcutSource, kCFRunLoopCommonModes);
    CGEventTapEnable(self.recordingShortcutTap, true);
    return YES;
}

- (void)removeRecordingShortcutTap {
    if (self.recordingShortcutSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.recordingShortcutSource, kCFRunLoopCommonModes);
        CFRelease(self.recordingShortcutSource);
        self.recordingShortcutSource = nullptr;
    }
    if (self.recordingShortcutTap) {
        CFMachPortInvalidate(self.recordingShortcutTap);
        CFRelease(self.recordingShortcutTap);
        self.recordingShortcutTap = nullptr;
    }
}

- (void)stopGlobalRecording {
    NSNumber *windowKey = self.globalRecordingWindowKey;
    CaptureRecorder *recorder = self.recorders[windowKey];
    if (!windowKey || !recorder) return;

    NSWindow *recordingWindow = nil;
    for (NSWindow *window in self.windows) {
        if ((CGWindowID)window.windowNumber == windowKey.unsignedIntValue) {
            recordingWindow = window;
            break;
        }
    }
    [self stopMousePassthroughForWindow:recordingWindow key:windowKey];
    [recorder stop];
}

- (void)setRecordingAppearance:(BOOL)recording forWindow:(NSWindow *)window {
    CaptureView *view = [window.contentView isKindOfClass:CaptureView.class]
        ? (CaptureView *)window.contentView
        : nil;
    view.recordingActive = recording;
}

- (void)flashCaptureBorderForWindow:(NSWindow *)window {
    CaptureView *view = [window.contentView isKindOfClass:CaptureView.class]
        ? (CaptureView *)window.contentView
        : nil;
    if (!view) return;

    view.captureFlashActive = YES;
    __weak CaptureView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kCaptureFlashDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        weakView.captureFlashActive = NO;
    });
}

- (void)dismissSelectionWindow {
    [self.selectionWindow orderOut:nil];
    self.selectionWindow = nil;
}

- (void)updateMousePassthrough {
    NSPoint mouseLocation = NSEvent.mouseLocation;
    for (NSWindow *window in self.windows) {
        NSNumber *windowKey = @((CGWindowID)window.windowNumber);
        BOOL shouldPassThrough = NO;
        if ([self.mousePassthroughWindowIDs containsObject:windowKey]) {
            NSPoint windowPoint = [window convertPointFromScreen:mouseLocation];
            NSPoint viewPoint = [window.contentView convertPoint:windowPoint fromView:nil];
            NSRect interactionRect = NSInsetRect(window.contentView.bounds, kResizeHitWidth, kResizeHitWidth);
            shouldPassThrough = NSPointInRect(viewPoint, interactionRect);
        }
        window.ignoresMouseEvents = shouldPassThrough;
    }
}

- (NSRect)componentFrameAtScreenPoint:(NSPoint)screenPoint {
    if (!self.selectionWindow) return NSZeroRect;

    CGFloat primaryTop = NSMaxY(NSScreen.screens.firstObject.frame);
    CGPoint quartzPoint = CGPointMake(screenPoint.x, primaryTop - screenPoint.y);
    CFArrayRef windowInfoRef = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenBelowWindow,
                                                          (CGWindowID)self.selectionWindow.windowNumber);
    NSArray *windowInfo = CFBridgingRelease(windowInfoRef);
    pid_t targetPID = 0;
    CGRect targetWindowFrame = CGRectZero;

    for (NSDictionary *info in windowInfo) {
        if ([info[(id)kCGWindowLayer] integerValue] != 0) continue;
        pid_t ownerPID = [info[(id)kCGWindowOwnerPID] intValue];
        if (ownerPID == NSProcessInfo.processInfo.processIdentifier) continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],
                                                     &bounds)) continue;
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
    AXError elementError = AXUIElementCopyElementAtPosition(application,
                                                             quartzPoint.x,
                                                             quartzPoint.y,
                                                             &element);
    if (elementError == kAXErrorSuccess && element) {
        CopyAXElementFrame(element, &componentFrame);
        CFRelease(element);
    }
    CFRelease(application);
    if (CGRectIsEmpty(componentFrame) || !CGRectContainsPoint(componentFrame, quartzPoint)) {
        componentFrame = targetWindowFrame;
    }

    return NSMakeRect(CGRectGetMinX(componentFrame),
                      primaryTop - CGRectGetMaxY(componentFrame),
                      CGRectGetWidth(componentFrame),
                      CGRectGetHeight(componentFrame));
}

- (void)toggleRecordingMouseInput:(id)sender {
    self.recordingMouseInputEnabled = !self.recordingMouseInputEnabled;
    self.recordingMouseInputItem.state = self.recordingMouseInputEnabled
        ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)restoreSaveDirectory {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kSaveFolderBookmarkKey];
    if (bookmark) {
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *folder = [NSURL URLByResolvingBookmarkData:bookmark
                                                  options:NSURLBookmarkResolutionWithSecurityScope
                                            relativeToURL:nil
                                      bookmarkDataIsStale:&stale
                                                    error:&error];
        if (folder && !stale) {
            self.saveDirectoryURL = folder;
            self.accessingSecurityScopedDirectory = [folder startAccessingSecurityScopedResource];
        }
    }
    if (!self.saveDirectoryURL) {
        self.saveDirectoryURL = [NSFileManager.defaultManager URLsForDirectory:NSDesktopDirectory
                                                                     inDomains:NSUserDomainMask].firstObject;
    }
}

- (void)chooseSaveLocation:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"캡처 저장 폴더 선택";
    panel.prompt = @"선택";
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = YES;
    panel.directoryURL = self.saveDirectoryURL;

    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;

        NSError *error = nil;
        NSData *bookmark = [panel.URL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                               includingResourceValuesForKeys:nil
                                                relativeToURL:nil
                                                        error:&error];
        if (!bookmark) {
            [self showAlertWithTitle:@"폴더 설정 실패"
                             message:error.localizedDescription
                              window:self.selectedWindow];
            return;
        }

        if (self.accessingSecurityScopedDirectory) {
            [self.saveDirectoryURL stopAccessingSecurityScopedResource];
        }
        self.saveDirectoryURL = panel.URL;
        self.accessingSecurityScopedDirectory = [panel.URL startAccessingSecurityScopedResource];
        [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kSaveFolderBookmarkKey];
    }];
}

- (NSURL *)mostRecentCaptureURL {
    if (self.lastCreatedFileURL &&
        [NSFileManager.defaultManager fileExistsAtPath:self.lastCreatedFileURL.path]) {
        return self.lastCreatedFileURL;
    }

    NSArray<NSURLResourceKey> *keys = @[NSURLContentModificationDateKey, NSURLIsRegularFileKey];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:self.saveDirectoryURL
      includingPropertiesForKeys:keys
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
    NSURL *newest = nil;
    NSDate *newestDate = nil;
    for (NSURL *file in files) {
        NSString *name = file.lastPathComponent;
        BOOL isCapture = ([name hasPrefix:@"PNClip "] && [name.pathExtension.lowercaseString isEqualToString:@"png"]) ||
                         ([name hasPrefix:@"PNClip Recording "] && [name.pathExtension.lowercaseString isEqualToString:@"gif"]);
        if (!isCapture) continue;
        NSDate *date = nil;
        [file getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        if (!newest || [date compare:newestDate] == NSOrderedDescending) {
            newest = file;
            newestDate = date;
        }
    }
    return newest;
}

- (void)openMostRecentCapture:(id)sender {
    NSURL *fileURL = [self mostRecentCaptureURL];
    if (fileURL) {
        [NSWorkspace.sharedWorkspace openURL:fileURL];
    } else {
        NSBeep();
    }
}

- (void)openSaveDirectory:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:self.saveDirectoryURL];
}

- (void)copyGIFAtURLToPasteboard:(NSURL *)fileURL {
    NSData *gifData = [NSData dataWithContentsOfURL:fileURL];
    if (!gifData) return;
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setData:gifData forType:(NSPasteboardType)UTTypeGIF.identifier];
    [item setString:fileURL.absoluteString forType:NSPasteboardTypeFileURL];
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard writeObjects:@[item]];
}

- (void)newWindow:(id)sender {
    [self createWindowWithFrame:NSZeroRect];
}

- (void)createWindowWithFrame:(NSRect)frame {
    BOOL usesDefaultFrame = NSIsEmptyRect(frame);
    NSRect initialFrame = usesDefaultFrame ? NSMakeRect(0, 0, 720, 450) : frame;
    NSWindow *window = [[CaptureWindow alloc]
        initWithContentRect:initialFrame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];

    window.backgroundColor = NSColor.clearColor;
    window.opaque = NO;
    window.hasShadow = NO;
    window.acceptsMouseMovedEvents = YES;
    window.level = NSFloatingWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.contentView = [[CaptureView alloc]
        initWithFrame:NSMakeRect(0, 0, NSWidth(initialFrame), NSHeight(initialFrame))];

    if (usesDefaultFrame) {
        [window center];
        CGFloat offset = 24.0 * self.windows.count;
        [window setFrameOrigin:NSMakePoint(NSMinX(window.frame) + offset,
                                          NSMinY(window.frame) - offset)];
    }
    [self.windows addObject:window];
    [window makeKeyAndOrderFront:nil];
}

- (void)closeCurrentWindow:(id)sender {
    [self.selectedWindow close];
}

- (void)closeAllWindows:(id)sender {
    for (NSWindow *window in self.windows.copy) {
        [window close];
    }
}

- (void)statusItemClicked:(id)sender {
    if (self.selectionWindow) return;

    NSDictionary *accessibilityOptions = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)accessibilityOptions);

    NSRect screenUnion = NSZeroRect;
    for (NSScreen *screen in NSScreen.screens) {
        screenUnion = NSIsEmptyRect(screenUnion) ? screen.frame : NSUnionRect(screenUnion, screen.frame);
    }
    self.selectionWindow = [[SelectionWindow alloc]
        initWithContentRect:screenUnion
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.selectionWindow.backgroundColor = NSColor.clearColor;
    self.selectionWindow.opaque = NO;
    self.selectionWindow.hasShadow = NO;
    self.selectionWindow.ignoresMouseEvents = NO;
    self.selectionWindow.acceptsMouseMovedEvents = YES;
    self.selectionWindow.level = NSScreenSaverWindowLevel;
    self.selectionWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                              NSWindowCollectionBehaviorFullScreenAuxiliary;

    SelectionView *selectionView = [[SelectionView alloc]
        initWithFrame:NSMakeRect(0, 0, NSWidth(screenUnion), NSHeight(screenUnion))];
    __weak AppDelegate *weakSelf = self;
    selectionView.completion = ^(NSRect selectedFrame) {
        AppDelegate *strongSelf = weakSelf;
        [strongSelf dismissSelectionWindow];
        [strongSelf createWindowWithFrame:selectedFrame];
    };
    selectionView.cancellation = ^{
        [weakSelf dismissSelectionWindow];
    };
    selectionView.componentFrameProvider = ^NSRect(NSPoint screenPoint) {
        return [weakSelf componentFrameAtScreenPoint:screenPoint];
    };
    self.selectionWindow.contentView = selectionView;
    [NSApp activateIgnoringOtherApps:YES];
    [self.selectionWindow makeKeyAndOrderFront:nil];
    [self.selectionWindow makeFirstResponder:selectionView];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (self.windows.count == 0) {
        [self newWindow:nil];
    } else if (!flag) {
        NSWindow *window = self.selectedWindow ? self.selectedWindow : self.windows.lastObject;
        [window makeKeyAndOrderFront:nil];
    }
    return YES;
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    self.selectedWindow = notification.object;
    CaptureView *view = (CaptureView *)self.selectedWindow.contentView;
    self.transparencySlider.doubleValue = view.interiorTransparency;
    self.transparencySlider.enabled = YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    NSWindow *window = notification.object;
    NSNumber *windowKey = @((CGWindowID)window.windowNumber);
    [self stopMousePassthroughForWindow:window key:windowKey];
    [self.recorders[windowKey] stop];
    if (self.selectedWindow == notification.object) {
        self.selectedWindow = nil;
    }
    [self.windows removeObject:notification.object];
    if (self.windows.count == 0) {
        self.transparencySlider.enabled = NO;
    }
}

- (void)capture:(id)sender {
    NSWindow *targetWindow = [self activeCaptureWindow];
    if (!targetWindow || ![self ensureScreenCaptureAccessForWindow:targetWindow]) return;
    [self flashCaptureBorderForWindow:targetWindow];

    NSRect contentRect = [targetWindow contentRectForFrameRect:targetWindow.frame];
    NSRect captureRect = NSInsetRect(contentRect, kBorderWidth, kBorderWidth);
    NSScreen *screen = targetWindow.screen ? targetWindow.screen : NSScreen.mainScreen;
    __weak AppDelegate *weakSelf = self;

    [self loadContentFilterForScreen:screen completion:^(SCContentFilter *filter, NSError *error) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error || !filter) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf showAlertWithTitle:@"캡처 실패"
                                       message:error.localizedDescription ? error.localizedDescription : @"화면 기록 권한을 확인해 주세요."
                                        window:targetWindow];
            });
            return;
        }

        SCStreamConfiguration *configuration = [strongSelf configurationForRect:captureRect
                                                                         onScreen:screen
                                                                   usesNativeScale:YES];

        [SCScreenshotManager captureImageWithFilter:filter
                                      configuration:configuration
                                  completionHandler:^(CGImageRef image, NSError *captureError) {
            if (captureError || image == nullptr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf showAlertWithTitle:@"캡처 실패"
                                           message:captureError.localizedDescription ? captureError.localizedDescription : @"이미지를 만들 수 없습니다."
                                            window:targetWindow];
                });
                return;
            }

            CGImageRef retainedImage = CGImageRetain(image);
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf saveCapturedImage:retainedImage];
                CGImageRelease(retainedImage);
            });
        }];
    }];
}

- (void)toggleRecording:(id)sender {
    NSWindow *targetWindow = [self activeCaptureWindow];
    if (!targetWindow) return;

    NSNumber *windowKey = @((CGWindowID)targetWindow.windowNumber);
    CaptureRecorder *existingRecorder = self.recorders[windowKey];
    if (existingRecorder) {
        [self stopMousePassthroughForWindow:targetWindow key:windowKey];
        [existingRecorder stop];
        return;
    }

    if (![self ensureScreenCaptureAccessForWindow:targetWindow]) return;

    NSRect contentRect = [targetWindow contentRectForFrameRect:targetWindow.frame];
    NSRect recordingRect = NSInsetRect(contentRect, kBorderWidth, kBorderWidth);
    NSScreen *screen = targetWindow.screen ? targetWindow.screen : NSScreen.mainScreen;

    CaptureRecorder *recorder = [[CaptureRecorder alloc]
        initWithWindowID:windowKey.unsignedIntValue
       destinationFolder:self.saveDirectoryURL];
    self.recorders[windowKey] = recorder;
    if (self.recordingMouseInputEnabled) {
        if (![self installRecordingShortcutTapForWindow:targetWindow]) {
            [self.recorders removeObjectForKey:windowKey];
            return;
        }
        self.globalRecordingWindowKey = windowKey;
        [self.mousePassthroughWindowIDs addObject:windowKey];
        [self updateMousePassthrough];
    }
    [self setRecordingAppearance:YES forWindow:targetWindow];
    __weak AppDelegate *weakSelf = self;
    __weak NSWindow *weakWindow = targetWindow;

    [self loadContentFilterForScreen:screen completion:^(SCContentFilter *filter, NSError *error) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error || !filter) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf.recorders removeObjectForKey:windowKey];
                [strongSelf stopMousePassthroughForWindow:weakWindow key:windowKey];
                [strongSelf setRecordingAppearance:NO forWindow:weakWindow];
                [strongSelf showAlertWithTitle:@"녹화 실패"
                                       message:error.localizedDescription ? error.localizedDescription : @"녹화할 디스플레이를 찾을 수 없습니다."
                                        window:weakWindow];
            });
            return;
        }

        SCStreamConfiguration *configuration = [strongSelf configurationForRect:recordingRect
                                                                         onScreen:screen
                                                                   usesNativeScale:NO];
        configuration.minimumFrameInterval = CMTimeMake(1, (int32_t)kRecordingFramesPerSecond);
        configuration.queueDepth = 8;
        configuration.pixelFormat = kCVPixelFormatType_32BGRA;
        configuration.showsCursor = NO;
        configuration.capturesAudio = NO;

        [recorder startWithFilter:filter
                    configuration:configuration
                      stopHandler:^{
            AppDelegate *stopSelf = weakSelf;
            [stopSelf stopMousePassthroughForWindow:weakWindow key:windowKey];
            [stopSelf setRecordingAppearance:NO forWindow:weakWindow];
        }
                       completion:^(NSURL *fileURL, NSError *recordingError) {
            AppDelegate *completionSelf = weakSelf;
            if (!completionSelf) return;
            if (completionSelf.recorders[windowKey] == recorder) {
                [completionSelf.recorders removeObjectForKey:windowKey];
            }
            if (recordingError) {
                NSBeep();
                [completionSelf showAlertWithTitle:@"녹화 실패"
                                           message:recordingError.localizedDescription
                                            window:weakWindow];
            } else if (fileURL) {
                completionSelf.lastCreatedFileURL = fileURL;
                [completionSelf copyGIFAtURLToPasteboard:fileURL];
            }
        }];
    }];
}

- (void)transparencyChanged:(NSSlider *)sender {
    CaptureView *view = (CaptureView *)self.selectedWindow.contentView;
    if (![view isKindOfClass:CaptureView.class]) return;
    view.interiorTransparency = sender.doubleValue;
    [view setNeedsDisplay:YES];
}

- (void)saveCapturedImage:(CGImageRef)image {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSURL *destination = TimestampedFileURL(self.saveDirectoryURL, @"PNClip", @"png");
    NSError *error = nil;
    if (![png writeToURL:destination options:NSDataWritingAtomic error:&error]) {
        NSBeep();
        [self showAlertWithTitle:@"저장 실패"
                         message:error.localizedDescription
                          window:NSApp.keyWindow];
        return;
    }

    self.lastCreatedFileURL = destination;
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setData:png forType:NSPasteboardTypePNG];
    NSImage *pasteImage = [[NSImage alloc] initWithCGImage:image size:NSZeroSize];
    NSData *tiff = pasteImage.TIFFRepresentation;
    if (tiff) [item setData:tiff forType:NSPasteboardTypeTIFF];
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard writeObjects:@[item]];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message window:(NSWindow *)window {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message ? message : @"알 수 없는 오류가 발생했습니다.";
    if (window) {
        [alert beginSheetModalForWindow:window completionHandler:nil];
    } else {
        [alert runModal];
    }
}

@end


static NSMenu *CreateMainMenu(AppDelegate *delegate) {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"PNClip"];
    NSMenuItem *launchAtLogin = [[NSMenuItem alloc]
        initWithTitle:@"로그인 시 실행"
               action:@selector(toggleLaunchAtLogin:)
        keyEquivalent:@""];
    launchAtLogin.target = delegate;
    delegate.launchAtLoginItem = launchAtLogin;
    [appMenu addItem:launchAtLogin];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"PNClip 종료"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;

    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:fileMenuItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"파일"];
    NSMenuItem *newWindow = [[NSMenuItem alloc] initWithTitle:@"새 창"
                                                      action:@selector(newWindow:)
                                               keyEquivalent:@"n"];
    newWindow.target = delegate;
    [fileMenu addItem:newWindow];
    NSMenuItem *newWindowWithTabShortcut = [[NSMenuItem alloc]
        initWithTitle:@"새 탭"
               action:@selector(newWindow:)
        keyEquivalent:@"t"];
    newWindowWithTabShortcut.target = delegate;
    [fileMenu addItem:newWindowWithTabShortcut];
    NSMenuItem *closeWindow = [[NSMenuItem alloc] initWithTitle:@"창 닫기"
                                                        action:@selector(closeCurrentWindow:)
                                                 keyEquivalent:@"w"];
    closeWindow.target = delegate;
    [fileMenu addItem:closeWindow];
    NSMenuItem *closeAllWindows = [[NSMenuItem alloc] initWithTitle:@"모든 창 닫기"
                                                            action:@selector(closeAllWindows:)
                                                     keyEquivalent:@"w"];
    closeAllWindows.keyEquivalentModifierMask = NSEventModifierFlagCommand |
                                                NSEventModifierFlagOption;
    closeAllWindows.target = delegate;
    [fileMenu addItem:closeAllWindows];
    [fileMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *openRecent = [[NSMenuItem alloc] initWithTitle:@"최근 캡처 열기"
                                                       action:@selector(openMostRecentCapture:)
                                                keyEquivalent:@"o"];
    openRecent.target = delegate;
    [fileMenu addItem:openRecent];
    NSMenuItem *openSaveDirectory = [[NSMenuItem alloc] initWithTitle:@"저장 폴더 열기"
                                                               action:@selector(openSaveDirectory:)
                                                        keyEquivalent:@"o"];
    openSaveDirectory.keyEquivalentModifierMask = NSEventModifierFlagCommand |
                                                  NSEventModifierFlagOption;
    openSaveDirectory.target = delegate;
    [fileMenu addItem:openSaveDirectory];
    [fileMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *saveLocation = [[NSMenuItem alloc] initWithTitle:@"저장 위치 변경…"
                                                          action:@selector(chooseSaveLocation:)
                                                   keyEquivalent:@""];
    saveLocation.target = delegate;
    [fileMenu addItem:saveLocation];
    fileMenuItem.submenu = fileMenu;

    NSMenuItem *captureMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:captureMenuItem];
    NSMenu *captureMenu = [[NSMenu alloc] initWithTitle:@"캡처"];
    NSMenuItem *capture = [[NSMenuItem alloc] initWithTitle:@"캡처"
                                                    action:@selector(capture:)
                                             keyEquivalent:@"s"];
    capture.target = delegate;
    [captureMenu addItem:capture];
    NSMenuItem *record = [[NSMenuItem alloc] initWithTitle:@"화면 녹화 시작/중지"
                                                    action:@selector(toggleRecording:)
                                             keyEquivalent:@"r"];
    record.target = delegate;
    [captureMenu addItem:record];
    [captureMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *recordingMouseInput = [[NSMenuItem alloc]
        initWithTitle:@"녹화 중 마우스 입력"
               action:@selector(toggleRecordingMouseInput:)
        keyEquivalent:@""];
    recordingMouseInput.target = delegate;
    recordingMouseInput.state = NSControlStateValueOff;
    delegate.recordingMouseInputItem = recordingMouseInput;
    [captureMenu addItem:recordingMouseInput];
    captureMenuItem.submenu = captureMenu;

    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:viewMenuItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"보기"];

    NSView *sliderContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 250, 48)];
    NSTextField *sliderLabel = [NSTextField labelWithString:@"중앙 투명도"];
    sliderLabel.frame = NSMakeRect(12, 25, 100, 18);
    [sliderContainer addSubview:sliderLabel];
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(108, 20, 130, 24)];
    slider.minValue = 0.0;
    slider.maxValue = 100.0;
    slider.doubleValue = 80.0;
    slider.continuous = YES;
    slider.target = delegate;
    slider.action = @selector(transparencyChanged:);
    delegate.transparencySlider = slider;
    [sliderContainer addSubview:slider];

    NSMenuItem *sliderItem = [[NSMenuItem alloc] init];
    sliderItem.view = sliderContainer;
    [viewMenu addItem:sliderItem];
    viewMenuItem.submenu = viewMenu;

    return mainMenu;
}

int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        application.mainMenu = CreateMainMenu(delegate);
        [application run];
    }
    return 0;
}
