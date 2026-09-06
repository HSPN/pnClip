#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import "AppDelegateMac.h"
#import "../Support/PNClipConstantsMac.h"
#import "../Support/AccessibilityElementDetectorMac.h"
#import "../Support/SourceWindowObserverMac.h"
#import "../UI/CaptureWindowMac.h"
#import "../UI/CaptureViewMac.h"
#import "../UI/SelectionWindowMac.h"
#import "../UI/SelectionViewMac.h"
#include "../Capture/CaptureBackendMac.hpp"
#include "../Core/AppController.hpp"
#include "../Support/PlatformServicesMac.hpp"

@interface AppDelegate () {
    std::unique_ptr<pnclip::CaptureBackend> _captureBackend;
    std::unique_ptr<pnclip::StartupBackend> _startupBackend;
    std::unique_ptr<pnclip::ShellBackend> _shellBackend;
    std::unique_ptr<pnclip::ClipboardBackend> _clipboardBackend;
    std::unique_ptr<pnclip::AppController> _appController;
}
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

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _captureBackend = pnclip::makeCaptureBackendMac();
    _startupBackend = pnclip::makeStartupBackendMac();
    _shellBackend = pnclip::makeShellBackendMac();
    _clipboardBackend = pnclip::makeClipboardBackendMac();
    _appController = std::make_unique<pnclip::AppController>(
        *_captureBackend, *_clipboardBackend, *_startupBackend, *_shellBackend);
    self.windows = [NSMutableArray array];
    self.selectionWindows = [NSMutableArray array];
    self.sourceWindowObservers = [NSMutableDictionary dictionary];
    self.mousePassthroughWindowIDs = [NSMutableSet set];
    self.recordingMouseInputEnabled = NO;
    self.recordingDuration = 5.0;
    self.recordingUsesNativeScale = NO;
    self.filenamePrefix = [NSUserDefaults.standardUserDefaults
        stringForKey:PNClipFilenamePrefixKey] ?: PNClipDefaultFilenamePrefix;
    self.captureFormat = (PNClipCaptureFormat)[NSUserDefaults.standardUserDefaults
        integerForKey:PNClipCaptureFormatKey];
    if (self.captureFormat != PNClipCaptureFormatWebP) {
        self.captureFormat = PNClipCaptureFormatPNGGIF;
    }
    self.pngGIFFormatItem.state = self.captureFormat == PNClipCaptureFormatPNGGIF
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.webPFormatItem.state = self.captureFormat == PNClipCaptureFormatWebP
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.elementDetector = [[AccessibilityElementDetector alloc] init];
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
    self.localKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                  handler:^NSEvent *(NSEvent *event) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.selectionWindows.count > 0 || NSApp.modalWindow) return event;

        NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if (event.keyCode == 8 && modifiers == NSEventModifierFlagCommand) {
            NSWindow *window = [strongSelf activeCaptureWindow];
            if (window && strongSelf->_appController->isRolling((pnclip::WindowId)window.windowNumber)) {
                [strongSelf saveRollingRecording:nil];
                return nil;
            }
        }
        if (event.keyCode == 17 && modifiers == NSEventModifierFlagCommand) {
            [strongSelf newWindow:nil];
            return nil;
        }

        NSEventModifierFlags escapeModifiers = modifiers & (NSEventModifierFlagCommand |
                                                              NSEventModifierFlagOption |
                                                              NSEventModifierFlagControl |
                                                              NSEventModifierFlagShift);
        if (event.keyCode == 53 && escapeModifiers == 0) {
            NSWindow *window = [strongSelf activeCaptureWindow];
            if (window && !window.attachedSheet) {
                [window close];
                return nil;
            }
        }
        return event;
    }];
    self.mouseTrackingTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                              repeats:YES
                                                                block:^(NSTimer *timer) {
        (void)timer;
        if (weakSelf.mousePassthroughWindowIDs.count > 0 || [weakSelf hasSourceTrackedWindow]) {
            [weakSelf updateMousePassthrough];
        }
    }];
    self.sourceRecoveryTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                               target:self
                                                             selector:@selector(updateSourceTrackedWindows)
                                                             userInfo:nil
                                                              repeats:YES];
    self.estimatedSizeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                              target:self
                                                            selector:@selector(updateEstimatedGIFSize:)
                                                            userInfo:nil
                                                             repeats:YES];
    [self updateEstimatedGIFSize:nil];
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
    self.launchAtLoginItem.state = _startupBackend->enabled()
        ? NSControlStateValueOn
        : NSControlStateValueOff;
}

- (void)toggleLaunchAtLogin:(id)sender {
    (void)sender;
    BOOL succeeded = _appController->setStartupEnabled(!_startupBackend->enabled());
    [self refreshLaunchAtLoginState];

    if (!succeeded) {
        [self showAlertWithTitle:@"자동 실행 설정 실패"
                         message:@"시스템의 로그인 항목 설정을 변경할 수 없습니다."
                          window:self.selectedWindow];
    } else if (_appController->startupRequiresApproval()) {
        _appController->openStartupApprovalSettings();
    }
}

- (void)showOpenSourceLicenses:(id)sender {
    (void)sender;
    if (!self.licenseWindow) {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *licensePath = [bundle pathForResource:@"libwebp-COPYING" ofType:@"txt"];
        NSString *patentPath = [bundle pathForResource:@"libwebp-PATENTS" ofType:@"txt"];
        NSString *license = licensePath
            ? [NSString stringWithContentsOfFile:licensePath encoding:NSUTF8StringEncoding error:nil]
            : nil;
        NSString *patents = patentPath
            ? [NSString stringWithContentsOfFile:patentPath encoding:NSUTF8StringEncoding error:nil]
            : nil;
        NSString *contents = [NSString stringWithFormat:
            @"libwebp 1.6.0\nCopyright (c) 2010, Google Inc.\n\n%@\n\n%@",
            license ?: @"라이선스 파일을 불러오지 못했습니다.",
            patents ?: @"특허 고지 파일을 불러오지 못했습니다."];

        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 680, 500)
                      styleMask:NSWindowStyleMaskTitled |
                                NSWindowStyleMaskClosable |
                                NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = @"오픈 소스 라이선스";
        window.minSize = NSMakeSize(480, 320);
        NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:window.contentView.bounds];
        scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scrollView.hasVerticalScroller = YES;
        scrollView.hasHorizontalScroller = NO;
        scrollView.borderType = NSBezelBorder;
        NSTextView *textView = [[NSTextView alloc] initWithFrame:scrollView.contentView.bounds];
        textView.editable = NO;
        textView.selectable = YES;
        textView.richText = NO;
        textView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
        textView.textContainerInset = NSMakeSize(12, 12);
        textView.string = contents;
        textView.autoresizingMask = NSViewWidthSizable;
        textView.verticallyResizable = YES;
        textView.horizontallyResizable = NO;
        textView.textContainer.widthTracksTextView = YES;
        scrollView.documentView = textView;
        window.contentView = scrollView;
        [window center];
        self.licenseWindow = window;
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.licenseWindow makeKeyAndOrderFront:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.globalMouseMonitor) [NSEvent removeMonitor:self.globalMouseMonitor];
    if (self.localMouseMonitor) [NSEvent removeMonitor:self.localMouseMonitor];
    if (self.localKeyMonitor) [NSEvent removeMonitor:self.localKeyMonitor];
    [self.mouseTrackingTimer invalidate];
    [self.sourceRecoveryTimer invalidate];
    [self.estimatedSizeTimer invalidate];
    [self removeRecordingShortcutTap];
    for (NSWindow *window in self.windows) {
        _appController->stopRecording((pnclip::WindowId)window.windowNumber);
        _appController->stopRolling((pnclip::WindowId)window.windowNumber);
    }
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

- (CGRect)pixelCropRectForCaptureWindow:(CaptureWindow *)window
                                  screen:(NSScreen *)screen
                         usesNativeScale:(BOOL)usesNativeScale {
    CGRect crop = window.sourceRectInWindow;
    if (window.sourceWindowID == 0 || CGRectIsEmpty(crop)) return CGRectZero;
    CGFloat scale = usesNativeScale ? screen.backingScaleFactor : 1.0;
    return CGRectMake(round(CGRectGetMinX(crop) * scale),
                      round(CGRectGetMinY(crop) * scale),
                      round(CGRectGetWidth(crop) * scale),
                      round(CGRectGetHeight(crop) * scale));
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
    if (!windowKey || !_appController->isRecording(windowKey.unsignedLongLongValue)) return;

    NSWindow *recordingWindow = nil;
    for (NSWindow *window in self.windows) {
        if ((CGWindowID)window.windowNumber == windowKey.unsignedIntValue) {
            recordingWindow = window;
            break;
        }
    }
    [self stopMousePassthroughForWindow:recordingWindow key:windowKey];
    _appController->stopRecording(windowKey.unsignedLongLongValue);
}

- (void)setRecordingAppearance:(BOOL)recording forWindow:(NSWindow *)window {
    CaptureView *view = [window.contentView isKindOfClass:CaptureView.class]
        ? (CaptureView *)window.contentView
        : nil;
    view.recordingActive = recording;
    [self updateEstimatedGIFSize:nil];
}

- (void)flashCaptureBorderForWindow:(NSWindow *)window {
    CaptureView *view = [window.contentView isKindOfClass:CaptureView.class]
        ? (CaptureView *)window.contentView
        : nil;
    if (!view) return;

    view.captureFlashActive = YES;
    __weak CaptureView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(PNClipCaptureFlashDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        weakView.captureFlashActive = NO;
    });
}

- (void)dismissSelectionWindow {
    for (SelectionWindow *window in self.selectionWindows) {
        [window orderOut:nil];
    }
    [self.selectionWindows removeAllObjects];
}

- (void)updateMousePassthrough {
    NSPoint mouseLocation = NSEvent.mouseLocation;
    for (NSWindow *window in self.windows) {
        NSNumber *windowKey = @((CGWindowID)window.windowNumber);
        BOOL shouldPassThrough = NO;
        BOOL followsSourceWindow = [window isKindOfClass:CaptureWindow.class] &&
                                   ((CaptureWindow *)window).sourceWindowID != 0;
        if (followsSourceWindow || [self.mousePassthroughWindowIDs containsObject:windowKey]) {
            NSPoint windowPoint = [window convertPointFromScreen:mouseLocation];
            NSPoint viewPoint = [window.contentView convertPoint:windowPoint fromView:nil];
            NSRect interactionRect = NSInsetRect(window.contentView.bounds,
                                                  PNClipMousePassthroughInset,
                                                  PNClipMousePassthroughInset);
            shouldPassThrough = NSPointInRect(viewPoint, interactionRect);
        }
        window.ignoresMouseEvents = shouldPassThrough;
    }
}

- (BOOL)hasSourceTrackedWindow {
    for (CaptureWindow *window in self.windows) {
        if ([window isKindOfClass:CaptureWindow.class] && window.sourceWindowID != 0) return YES;
    }
    return NO;
}

- (void)updateSourceTrackedWindows {
    for (CaptureWindow *window in self.windows) {
        if ([window isKindOfClass:CaptureWindow.class] && window.sourceWindowID != 0)
            [self updateSourceTrackedWindow:window];
    }
}

- (void)updateSourceTrackedWindow:(CaptureWindow *)window {
    if (!window || window.sourceWindowID == 0) return;
    NSArray<NSDictionary *> *windowInfo = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionIncludingWindow, window.sourceWindowID));
    NSDictionary *info = windowInfo.firstObject;
    CGRect bounds = CGRectZero;
    if (!info || !CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds)) return;
    CGFloat primaryTop = NSMaxY(NSScreen.screens.firstObject.frame);
    window.sourceWindowBounds = bounds;
    CGRect crop = window.sourceRectInWindow;
    if (CGRectIsEmpty(crop)) {
        crop = CGRectMake(0, 0, CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    }
    NSRect selectedFrame = NSMakeRect(CGRectGetMinX(bounds) + CGRectGetMinX(crop),
                                      primaryTop - CGRectGetMinY(bounds) - CGRectGetMaxY(crop),
                                      CGRectGetWidth(crop), CGRectGetHeight(crop));
    NSRect trackedFrame = NSInsetRect(selectedFrame, -PNClipBorderWidth, -PNClipBorderWidth);
    if (!NSEqualRects(window.frame, trackedFrame)) [window setFrame:trackedFrame display:YES];
}

- (NSRect)componentFrameAtScreenPoint:(NSPoint)screenPoint
                           belowWindow:(SelectionWindow *)overlayWindow {
    if (![self.selectionWindows containsObject:overlayWindow]) return NSZeroRect;
    return [self.elementDetector componentFrameAtScreenPoint:screenPoint
                                                  belowWindow:overlayWindow
                                          excludingProcessID:NSProcessInfo.processInfo.processIdentifier];
}

- (void)toggleRecordingMouseInput:(id)sender {
    self.recordingMouseInputEnabled = !self.recordingMouseInputEnabled;
    self.recordingMouseInputItem.state = self.recordingMouseInputEnabled
        ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)restoreSaveDirectory {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:PNClipSaveFolderBookmarkKey];
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
        [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:PNClipSaveFolderBookmarkKey];
    }];
}

- (void)changeFilenamePrefix:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"저장 파일명";
    alert.informativeText = @"모든 캡처 및 녹화 파일명 앞에 붙을 접두사를 입력하세요.";
    [alert addButtonWithTitle:@"저장"];
    [alert addButtonWithTitle:@"취소"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    field.stringValue = self.filenamePrefix;
    field.placeholderString = PNClipDefaultFilenamePrefix;
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;

    NSModalResponse response = [alert runModal];
    if (response != NSAlertFirstButtonReturn) return;

    NSString *prefix = [field.stringValue stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *invalidCharacters = [NSCharacterSet characterSetWithCharactersInString:@"/:\n\r"];
    if (prefix.length == 0 || prefix.length > 120 ||
        [prefix rangeOfCharacterFromSet:invalidCharacters].location != NSNotFound) {
        [self showAlertWithTitle:@"파일명 변경 실패"
                         message:@"접두사는 1~120자여야 하며 /, :, 줄바꿈을 포함할 수 없습니다."
                          window:self.selectedWindow];
        return;
    }

    self.filenamePrefix = prefix;
    [NSUserDefaults.standardUserDefaults setObject:prefix forKey:PNClipFilenamePrefixKey];
    _appController->updateFilenamePrefix(prefix.UTF8String ?: "PNClip");
}

- (void)selectCaptureFormat:(NSMenuItem *)sender {
    if (!self.pngGIFFormatItem.enabled) return;
    self.captureFormat = sender.tag == PNClipCaptureFormatWebP
        ? PNClipCaptureFormatWebP : PNClipCaptureFormatPNGGIF;
    self.pngGIFFormatItem.state = self.captureFormat == PNClipCaptureFormatPNGGIF
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.webPFormatItem.state = self.captureFormat == PNClipCaptureFormatWebP
        ? NSControlStateValueOn : NSControlStateValueOff;
    [NSUserDefaults.standardUserDefaults setInteger:self.captureFormat
                                             forKey:PNClipCaptureFormatKey];
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
        NSString *extension = name.pathExtension.lowercaseString;
        BOOL supportedExtension = [extension isEqualToString:@"png"] ||
                                  [extension isEqualToString:@"gif"] ||
                                  [extension isEqualToString:@"webp"];
        BOOL isCapture = supportedExtension &&
                         [name hasPrefix:[self.filenamePrefix stringByAppendingString:@" "]];
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
    if (fileURL && _appController->open(fileURL.fileSystemRepresentation)) {
    } else {
        NSBeep();
    }
}

- (void)openSaveDirectory:(id)sender {
    if (self.saveDirectoryURL.fileSystemRepresentation) {
        _appController->open(self.saveDirectoryURL.fileSystemRepresentation);
    }
}

- (void)copyAnimatedImageAtURLToPasteboard:(NSURL *)fileURL {
    if (fileURL.fileSystemRepresentation) {
        _appController->copyFile(fileURL.fileSystemRepresentation);
    }
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

- (void)createWindowForSelectionTarget:(PNClipSelectionTarget *)target {
    if (!target || target.windowID == 0 || NSIsEmptyRect(target.selectedFrame)) return;
    [self createWindowWithFrame:NSInsetRect(target.selectedFrame,
                                             -PNClipBorderWidth,
                                             -PNClipBorderWidth)];
    CaptureWindow *window = (CaptureWindow *)self.windows.lastObject;
    window.sourceWindowID = target.windowID;
    window.sourceWindowBounds = target.windowBounds;
    CGFloat primaryTop = NSMaxY(NSScreen.screens.firstObject.frame);
    CGRect selectedQuartz = CGRectMake(NSMinX(target.selectedFrame),
                                        primaryTop - NSMaxY(target.selectedFrame),
                                        NSWidth(target.selectedFrame),
                                        NSHeight(target.selectedFrame));
    CGRect crop = CGRectMake(CGRectGetMinX(selectedQuartz) - CGRectGetMinX(target.windowBounds),
                             CGRectGetMinY(selectedQuartz) - CGRectGetMinY(target.windowBounds),
                             CGRectGetWidth(selectedQuartz), CGRectGetHeight(selectedQuartz));
    BOOL selectsWholeWindow = fabs(CGRectGetMinX(crop)) < 1.0 &&
                              fabs(CGRectGetMinY(crop)) < 1.0 &&
                              fabs(CGRectGetWidth(crop) - CGRectGetWidth(target.windowBounds)) < 1.0 &&
                              fabs(CGRectGetHeight(crop) - CGRectGetHeight(target.windowBounds)) < 1.0;
    window.sourceRectInWindow = selectsWholeWindow ? CGRectZero : crop;
    CaptureView *view = (CaptureView *)window.contentView;
    view.sourceGeometryLocked = YES;
    [window invalidateCursorRectsForView:view];
    if (target.accessibilityWindow) {
        NSNumber *windowKey = @((CGWindowID)window.windowNumber);
        __weak AppDelegate *weakSelf = self;
        __weak CaptureWindow *weakWindow = window;
        SourceWindowObserver *observer = [[SourceWindowObserver alloc]
            initWithProcessID:target.processID
                       window:(__bridge AXUIElementRef)target.accessibilityWindow
                      handler:^(CFStringRef notification) {
            AppDelegate *strongSelf = weakSelf;
            CaptureWindow *strongWindow = weakWindow;
            if (!strongSelf || !strongWindow) return;
            if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
                [strongWindow close];
                return;
            }
            [strongSelf updateSourceTrackedWindow:strongWindow];
        }];
        if (observer.isActive) self.sourceWindowObservers[windowKey] = observer;
    }
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
    if (self.selectionWindows.count > 0) return;

    NSDictionary *accessibilityOptions = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)accessibilityOptions);

    __weak AppDelegate *weakSelf = self;
    SelectionWindow *keyOverlayWindow = nil;
    for (NSScreen *screen in NSScreen.screens) {
        SelectionWindow *overlayWindow = [[SelectionWindow alloc]
            initWithContentRect:screen.frame
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        overlayWindow.backgroundColor = NSColor.clearColor;
        overlayWindow.opaque = NO;
        overlayWindow.hasShadow = NO;
        overlayWindow.ignoresMouseEvents = NO;
        overlayWindow.acceptsMouseMovedEvents = YES;
        overlayWindow.level = NSScreenSaverWindowLevel;
        overlayWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                           NSWindowCollectionBehaviorFullScreenAuxiliary;

        SelectionView *selectionView = [[SelectionView alloc]
            initWithFrame:NSMakeRect(0, 0, NSWidth(screen.frame), NSHeight(screen.frame))];
        __weak SelectionWindow *weakOverlayWindow = overlayWindow;
        selectionView.completion = ^(NSRect selectedFrame) {
            AppDelegate *strongSelf = weakSelf;
            [strongSelf dismissSelectionWindow];
            [strongSelf createWindowWithFrame:selectedFrame];
        };
        selectionView.componentCompletion = ^(NSRect componentFrame, NSPoint detectionPoint) {
            AppDelegate *strongSelf = weakSelf;
            PNClipSelectionTarget *target = [strongSelf.elementDetector
                selectionTargetAtScreenPoint:detectionPoint
                                   belowWindow:weakOverlayWindow
                           excludingProcessID:NSProcessInfo.processInfo.processIdentifier];
            target.selectedFrame = componentFrame;
            [strongSelf dismissSelectionWindow];
            [strongSelf createWindowForSelectionTarget:target];
        };
        selectionView.cancellation = ^{
            [weakSelf dismissSelectionWindow];
        };
        selectionView.componentFrameProvider = ^NSRect(NSPoint screenPoint) {
            return [weakSelf componentFrameAtScreenPoint:screenPoint
                                             belowWindow:weakOverlayWindow];
        };
        overlayWindow.contentView = selectionView;
        [overlayWindow makeFirstResponder:selectionView];
        [self.selectionWindows addObject:overlayWindow];
        [overlayWindow orderFront:nil];
        if (!keyOverlayWindow || NSPointInRect(NSEvent.mouseLocation, screen.frame)) {
            keyOverlayWindow = overlayWindow;
        }
    }

    [NSApp activateIgnoringOtherApps:YES];
    [keyOverlayWindow makeKeyAndOrderFront:nil];
}

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification {
    (void)notification;
    if (self.selectionWindows.count > 0) {
        [self dismissSelectionWindow];
    }
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
    pnclip::WindowId windowKey = (pnclip::WindowId)self.selectedWindow.windowNumber;
    self.rollingRecordingItem.state = _appController->isRolling(windowKey)
        ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)windowWillClose:(NSNotification *)notification {
    NSWindow *window = notification.object;
    NSNumber *windowKey = @((CGWindowID)window.windowNumber);
    [self stopMousePassthroughForWindow:window key:windowKey];
    _appController->stopRecording(windowKey.unsignedLongLongValue);
    _appController->stopRolling(windowKey.unsignedLongLongValue);
    [self.sourceWindowObservers removeObjectForKey:windowKey];
    if (self.selectedWindow == notification.object) {
        self.selectedWindow = nil;
    }
    [self.windows removeObject:notification.object];
    if (self.windows.count == 0) {
        self.transparencySlider.enabled = NO;
    }
    [self updateEstimatedGIFSize:nil];
}

- (void)updateCoreCaptureSettings {
    pnclip::CaptureSettings settings;
    if (self.saveDirectoryURL.fileSystemRepresentation) {
        settings.destinationFolder = self.saveDirectoryURL.fileSystemRepresentation;
    }
    settings.filenamePrefix = self.filenamePrefix.UTF8String ?: "PNClip";
    settings.format = self.captureFormat == PNClipCaptureFormatWebP
        ? pnclip::CaptureFormat::webP : pnclip::CaptureFormat::pngGif;
    settings.maximumDuration = std::chrono::milliseconds(
        (long long)llround(self.recordingDuration * 1000.0));
    settings.framesPerSecond = (uint32_t)PNClipRecordingFramesPerSecond;
    settings.nativeScale = self.recordingUsesNativeScale;
    _appController->updateSettings(std::move(settings));
}

- (pnclip::CaptureTarget)captureTargetForWindow:(CaptureWindow *)window
                                          rect:(NSRect)region
                                        screen:(NSScreen *)screen
                               usesNativeScale:(BOOL)usesNativeScale {
    pnclip::CaptureTarget target;
    target.sessionId = (pnclip::WindowId)window.windowNumber;
    target.displayId = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    target.sourceWindow = window.sourceWindowID;
    target.source = window.sourceWindowID ? pnclip::CaptureSource::window
                                          : pnclip::CaptureSource::display;
    target.captureArea = {NSMinX(region) - NSMinX(screen.frame),
                          NSMaxY(screen.frame) - NSMaxY(region),
                          NSWidth(region), NSHeight(region)};
    target.sourceWindowSize = {0, 0, window.sourceWindowBounds.size.width,
                               window.sourceWindowBounds.size.height};
    CGRect crop = [self pixelCropRectForCaptureWindow:window screen:screen
                                      usesNativeScale:usesNativeScale];
    target.cropPixels = {crop.origin.x, crop.origin.y, crop.size.width, crop.size.height};
    target.nativeScale = usesNativeScale;
    target.pixelScale = screen.backingScaleFactor;
    for (NSWindow *excluded in self.windows) {
        target.excludedWindows.push_back((pnclip::WindowId)excluded.windowNumber);
    }
    return target;
}

- (void)capture:(id)sender {
    NSWindow *targetWindow = [self activeCaptureWindow];
    if (!targetWindow || ![self ensureScreenCaptureAccessForWindow:targetWindow]) return;
    [self flashCaptureBorderForWindow:targetWindow];
    CaptureWindow *window = (CaptureWindow *)targetWindow;
    NSScreen *screen = targetWindow.screen ?: NSScreen.mainScreen;
    NSRect content = [targetWindow contentRectForFrameRect:targetWindow.frame];
    NSRect region = NSInsetRect(content, PNClipBorderWidth, PNClipBorderWidth);
    pnclip::CaptureTarget target = [self captureTargetForWindow:window rect:region screen:screen
                                               usesNativeScale:YES];
    __weak AppDelegate *weakSelf = self;
    _appController->capture(target, [weakSelf, targetWindow](pnclip::PixelBuffer pixels,
                                                                  pnclip::ServiceError error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error.code || !pixels.valid()) {
                [strongSelf showAlertWithTitle:@"캡처 실패"
                    message:[NSString stringWithUTF8String:error.message.c_str()] window:targetWindow];
                return;
            }
            CFDataRef data = CFDataCreate(kCFAllocatorDefault,
                reinterpret_cast<const UInt8 *>(pixels.bytes.data()), pixels.bytes.size());
            CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
            CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGImageRef image = CGImageCreate(pixels.width, pixels.height, 8, 32, pixels.stride,
                colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                provider, nullptr, false, kCGRenderingIntentDefault);
            CGColorSpaceRelease(colorSpace); CGDataProviderRelease(provider); CFRelease(data);
            if (image) { [strongSelf saveCapturedImage:image]; CGImageRelease(image); }
        });
    });
}

- (void)toggleRecording:(id)sender {
    NSWindow *targetWindow = [self activeCaptureWindow];
    if (!targetWindow) return;
    pnclip::WindowId key = (pnclip::WindowId)targetWindow.windowNumber;
    NSNumber *windowKey = @(key);
    BOOL willStart = !_appController->isRolling(key) && !_appController->isRecording(key);
    if (willStart && ![self ensureScreenCaptureAccessForWindow:targetWindow]) return;
    if (willStart && self.recordingMouseInputEnabled &&
        ![self installRecordingShortcutTapForWindow:targetWindow]) {
        return;
    }
    CaptureWindow *window = (CaptureWindow *)targetWindow;
    NSScreen *screen = targetWindow.screen ?: NSScreen.mainScreen;
    NSRect content = [targetWindow contentRectForFrameRect:targetWindow.frame];
    pnclip::CaptureTarget target = [self captureTargetForWindow:window
        rect:NSInsetRect(content, PNClipBorderWidth, PNClipBorderWidth) screen:screen
        usesNativeScale:self.recordingUsesNativeScale];
    [self updateCoreCaptureSettings];
    __weak AppDelegate *weakSelf = self;
    __weak NSWindow *weakWindow = targetWindow;
    auto outcome = _appController->toggleRecording(target, [weakSelf, weakWindow, windowKey](
        std::filesystem::path path, pnclip::ServiceError error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf stopMousePassthroughForWindow:weakWindow key:windowKey];
            [strongSelf setRecordingAppearance:NO forWindow:weakWindow];
            if (error.code) {
                NSBeep();
                [strongSelf showAlertWithTitle:@"녹화 실패"
                    message:[NSString stringWithUTF8String:error.message.c_str()] window:weakWindow];
            } else if (!path.empty()) {
                NSURL *url = [NSURL fileURLWithFileSystemRepresentation:path.c_str()
                    isDirectory:NO relativeToURL:nil];
                strongSelf.lastCreatedFileURL = url;
                [strongSelf copyAnimatedImageAtURLToPasteboard:url];
            }
        });
    });
    if (outcome == pnclip::RecordingToggleResult::stoppedRolling) {
        ((CaptureView *)targetWindow.contentView).rollingRecordingActive = NO;
        self.rollingRecordingItem.state = NSControlStateValueOff;
        [self updateEstimatedGIFSize:nil];
    } else if (outcome == pnclip::RecordingToggleResult::stopped) {
        [self stopMousePassthroughForWindow:targetWindow key:windowKey];
    } else if (outcome == pnclip::RecordingToggleResult::started) {
        if (self.recordingMouseInputEnabled) {
            self.globalRecordingWindowKey = windowKey;
            [self.mousePassthroughWindowIDs addObject:windowKey];
            [self updateMousePassthrough];
        }
        [self setRecordingAppearance:YES forWindow:targetWindow];
    } else if (outcome == pnclip::RecordingToggleResult::invalidTarget) {
        NSBeep();
        [self showAlertWithTitle:@"녹화 실패" message:@"캡처 영역이 올바르지 않습니다."
            window:targetWindow];
    }
}

- (void)toggleRollingRecording:(id)sender {
    NSWindow *targetWindow = [self activeCaptureWindow];
    if (!targetWindow) return;
    pnclip::WindowId key = (pnclip::WindowId)targetWindow.windowNumber;
    CaptureView *view = (CaptureView *)targetWindow.contentView;
    BOOL willStart = !_appController->isRolling(key) && !_appController->isRecording(key);
    if (willStart && ![self ensureScreenCaptureAccessForWindow:targetWindow]) return;
    CaptureWindow *window = (CaptureWindow *)targetWindow;
    NSScreen *screen = targetWindow.screen ?: NSScreen.mainScreen;
    NSRect content = [targetWindow contentRectForFrameRect:targetWindow.frame];
    pnclip::CaptureTarget target = [self captureTargetForWindow:window
        rect:NSInsetRect(content, PNClipBorderWidth, PNClipBorderWidth) screen:screen
        usesNativeScale:self.recordingUsesNativeScale];
    [self updateCoreCaptureSettings];
    __weak AppDelegate *weakSelf = self;
    __weak NSWindow *weakWindow = targetWindow;
    auto outcome = _appController->toggleRolling(target, [weakSelf, weakWindow](std::filesystem::path path,
                                                               pnclip::ServiceError error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error.code) {
                ((CaptureView *)weakWindow.contentView).rollingRecordingActive = NO;
                strongSelf.rollingRecordingItem.state = NSControlStateValueOff;
                [strongSelf updateEstimatedGIFSize:nil];
                NSBeep();
                [strongSelf showAlertWithTitle:@"상시 녹화 실패"
                    message:[NSString stringWithUTF8String:error.message.c_str()] window:weakWindow];
            } else if (!path.empty()) {
                NSURL *url = [NSURL fileURLWithFileSystemRepresentation:path.c_str()
                    isDirectory:NO relativeToURL:nil];
                strongSelf.lastCreatedFileURL = url;
                [strongSelf copyAnimatedImageAtURLToPasteboard:url];
            }
        });
    });
    if (outcome == pnclip::RecordingToggleResult::started) {
        view.rollingRecordingActive = YES;
        self.rollingRecordingItem.state = NSControlStateValueOn;
        [self updateEstimatedGIFSize:nil];
    } else if (outcome == pnclip::RecordingToggleResult::stopped) {
        view.rollingRecordingActive = NO;
        self.rollingRecordingItem.state = NSControlStateValueOff;
        [self updateEstimatedGIFSize:nil];
    } else if (outcome == pnclip::RecordingToggleResult::blockedByRecording) {
        NSBeep();
        [self showAlertWithTitle:@"상시 녹화 시작 불가"
            message:@"일반 녹화를 먼저 중지해 주세요." window:targetWindow];
    } else if (outcome == pnclip::RecordingToggleResult::invalidTarget) {
        NSBeep();
        [self showAlertWithTitle:@"상시 녹화 실패" message:@"캡처 영역이 올바르지 않습니다."
            window:targetWindow];
    }
}

- (void)saveRollingRecording:(id)sender {
    NSWindow *targetWindow = [self activeCaptureWindow];
    if (!targetWindow) return;
    pnclip::WindowId key = (pnclip::WindowId)targetWindow.windowNumber;
    if (!_appController->isRolling(key)) return;
    _appController->saveRolling(key, std::chrono::milliseconds(
        (long long)llround(self.recordingDuration * 1000.0)));
}

- (void)selectRecordingDuration:(NSMenuItem *)sender {
    if (!self.fiveSecondItem.enabled) return;
    self.recordingDuration = sender.tag == 10 ? 10.0 : 5.0;
    self.fiveSecondItem.state = self.recordingDuration == 5.0
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.tenSecondItem.state = self.recordingDuration == 10.0
        ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateEstimatedGIFSize:nil];
}

- (void)selectRecordingScale:(NSMenuItem *)sender {
    if (!self.standardScaleItem.enabled) return;
    self.recordingUsesNativeScale = sender.tag == 2;
    self.standardScaleItem.state = self.recordingUsesNativeScale
        ? NSControlStateValueOff : NSControlStateValueOn;
    self.retinaScaleItem.state = self.recordingUsesNativeScale
        ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateEstimatedGIFSize:nil];
}

- (void)updateEstimatedGIFSize:(NSTimer *)timer {
    BOOL hasActiveRecording = NO;
    for (NSWindow *candidate in self.windows) {
        CaptureView *view = (CaptureView *)candidate.contentView;
        if ([view isKindOfClass:CaptureView.class] &&
            (view.isRecordingActive || view.isRollingRecordingActive)) {
            hasActiveRecording = YES;
            break;
        }
    }
    self.estimatedSizeItem.hidden = !hasActiveRecording;
    self.fiveSecondItem.enabled = !hasActiveRecording;
    self.tenSecondItem.enabled = !hasActiveRecording;
    self.standardScaleItem.enabled = !hasActiveRecording;
    self.retinaScaleItem.enabled = !hasActiveRecording;
    self.pngGIFFormatItem.enabled = !hasActiveRecording;
    self.webPFormatItem.enabled = !hasActiveRecording;
    if (!hasActiveRecording) return;

    NSWindow *window = [self activeCaptureWindow];
    pnclip::WindowId windowKey = window ? (pnclip::WindowId)window.windowNumber : 0;
    if (!windowKey || (!_appController->isRecording(windowKey) && !_appController->isRolling(windowKey))) {
        for (NSWindow *candidate in self.windows) {
            pnclip::WindowId candidateKey = (pnclip::WindowId)candidate.windowNumber;
            if (_appController->isRecording(candidateKey) || _appController->isRolling(candidateKey)) {
                window = candidate;
                windowKey = candidateKey;
                break;
            }
        }
    }
    if (!window || !windowKey) {
        NSString *title = @"예상 GIF: -- MB";
        self.estimatedSizeItem.title = title;
        self.estimatedSizeItem.submenu.title = title;
        return;
    }
    unsigned long long bytes = _appController->isRolling(windowKey)
        ? _appController->estimatedRollingSize(windowKey, std::chrono::milliseconds(
            (long long)llround(self.recordingDuration * 1000.0)))
        : _appController->estimatedRecordingSize(windowKey);
    NSString *formatName = self.captureFormat == PNClipCaptureFormatWebP ? @"WebP" : @"GIF";
    NSString *title = [NSString stringWithFormat:@"예상 %@: %.1f MB", formatName,
        bytes / (1024.0 * 1024.0)];
    self.estimatedSizeItem.title = title;
    self.estimatedSizeItem.submenu.title = title;
}

- (void)transparencyChanged:(NSSlider *)sender {
    CaptureView *view = (CaptureView *)self.selectedWindow.contentView;
    if (![view isKindOfClass:CaptureView.class]) return;
    view.interiorTransparency = sender.doubleValue;
    [view setNeedsDisplay:YES];
}

- (void)saveCapturedImage:(CGImageRef)image {
    NSError *error = nil;
    NSData *imageData = PNClipEncodeStillImage(image, self.captureFormat, &error);
    NSString *extension = PNClipStillImageExtension(self.captureFormat);
    NSURL *destination = PNClipTimestampedFileURL(self.saveDirectoryURL,
                                                   self.filenamePrefix, extension);
    if (!imageData || ![imageData writeToURL:destination options:NSDataWritingAtomic error:&error]) {
        NSBeep();
        [self showAlertWithTitle:@"저장 실패"
                         message:error.localizedDescription
                          window:NSApp.keyWindow];
        return;
    }

    self.lastCreatedFileURL = destination;
    _appController->copyFile(destination.fileSystemRepresentation);
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
