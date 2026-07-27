#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AppDelegate.h"
#import "../Capture/CaptureRecorder.h"
#import "../Capture/RollingCaptureRecorder.h"
#import "../Support/PNClipConstants.h"
#import "../Support/AccessibilityElementDetector.h"
#import "../UI/CaptureWindow.h"
#import "../UI/CaptureView.h"
#import "../UI/SelectionWindow.h"
#import "../UI/SelectionView.h"

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
    self.windows = [NSMutableArray array];
    self.selectionWindows = [NSMutableArray array];
    self.recorders = [NSMutableDictionary dictionary];
    self.rollingRecorders = [NSMutableDictionary dictionary];
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
            NSNumber *windowKey = window ? @((CGWindowID)window.windowNumber) : nil;
            if (windowKey && strongSelf.rollingRecorders[windowKey]) {
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
        if (weakSelf.mousePassthroughWindowIDs.count > 0) {
            [weakSelf updateMousePassthrough];
        }
    }];
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
    [self.estimatedSizeTimer invalidate];
    [self removeRecordingShortcutTap];
    for (RollingCaptureRecorder *recorder in self.rollingRecorders.allValues) [recorder stop];
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
            NSError *displayError = [NSError errorWithDomain:PNClipErrorDomain
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
        if ([self.mousePassthroughWindowIDs containsObject:windowKey]) {
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
    for (CaptureRecorder *recorder in self.recorders.allValues) {
        recorder.filenamePrefix = prefix;
    }
    for (RollingCaptureRecorder *recorder in self.rollingRecorders.allValues) {
        recorder.filenamePrefix = prefix;
    }
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
    if (fileURL) {
        [NSWorkspace.sharedWorkspace openURL:fileURL];
    } else {
        NSBeep();
    }
}

- (void)openSaveDirectory:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:self.saveDirectoryURL];
}

- (void)copyAnimatedImageAtURLToPasteboard:(NSURL *)fileURL {
    NSData *imageData = [NSData dataWithContentsOfURL:fileURL];
    if (!imageData) return;
    UTType *type = [UTType typeWithFilenameExtension:fileURL.pathExtension];
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    if (type) [item setData:imageData forType:(NSPasteboardType)type.identifier];
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
        selectionView.completion = ^(NSRect selectedFrame) {
            AppDelegate *strongSelf = weakSelf;
            [strongSelf dismissSelectionWindow];
            [strongSelf createWindowWithFrame:selectedFrame];
        };
        selectionView.componentCompletion = ^(NSRect componentFrame) {
            AppDelegate *strongSelf = weakSelf;
            [strongSelf dismissSelectionWindow];
            NSRect windowFrame = NSInsetRect(componentFrame, -PNClipBorderWidth, -PNClipBorderWidth);
            [strongSelf createWindowWithFrame:windowFrame];
        };
        selectionView.cancellation = ^{
            [weakSelf dismissSelectionWindow];
        };
        __weak SelectionWindow *weakOverlayWindow = overlayWindow;
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
    NSNumber *windowKey = @((CGWindowID)self.selectedWindow.windowNumber);
    self.rollingRecordingItem.state = self.rollingRecorders[windowKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)windowWillClose:(NSNotification *)notification {
    NSWindow *window = notification.object;
    NSNumber *windowKey = @((CGWindowID)window.windowNumber);
    [self stopMousePassthroughForWindow:window key:windowKey];
    [self.recorders[windowKey] stop];
    [self.rollingRecorders[windowKey] stop];
    [self.rollingRecorders removeObjectForKey:windowKey];
    if (self.selectedWindow == notification.object) {
        self.selectedWindow = nil;
    }
    [self.windows removeObject:notification.object];
    if (self.windows.count == 0) {
        self.transparencySlider.enabled = NO;
    }
    [self updateEstimatedGIFSize:nil];
}

- (void)capture:(id)sender {
    NSWindow *targetWindow = [self activeCaptureWindow];
    if (!targetWindow || ![self ensureScreenCaptureAccessForWindow:targetWindow]) return;
    [self flashCaptureBorderForWindow:targetWindow];

    NSRect contentRect = [targetWindow contentRectForFrameRect:targetWindow.frame];
    NSRect captureRect = NSInsetRect(contentRect, PNClipBorderWidth, PNClipBorderWidth);
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
    RollingCaptureRecorder *rollingRecorder = self.rollingRecorders[windowKey];
    if (rollingRecorder) {
        [rollingRecorder stop];
        [self.rollingRecorders removeObjectForKey:windowKey];
        ((CaptureView *)targetWindow.contentView).rollingRecordingActive = NO;
        self.rollingRecordingItem.state = NSControlStateValueOff;
        [self updateEstimatedGIFSize:nil];
        return;
    }
    CaptureRecorder *existingRecorder = self.recorders[windowKey];
    if (existingRecorder) {
        [self stopMousePassthroughForWindow:targetWindow key:windowKey];
        [existingRecorder stop];
        return;
    }

    if (![self ensureScreenCaptureAccessForWindow:targetWindow]) return;

    NSRect contentRect = [targetWindow contentRectForFrameRect:targetWindow.frame];
    NSRect recordingRect = NSInsetRect(contentRect, PNClipBorderWidth, PNClipBorderWidth);
    NSScreen *screen = targetWindow.screen ? targetWindow.screen : NSScreen.mainScreen;
    BOOL usesNativeScale = self.recordingUsesNativeScale;

    CaptureRecorder *recorder = [[CaptureRecorder alloc]
        initWithWindowID:windowKey.unsignedIntValue
       destinationFolder:self.saveDirectoryURL
          maximumDuration:self.recordingDuration
            filenamePrefix:self.filenamePrefix
              captureFormat:self.captureFormat];
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
                                                                   usesNativeScale:usesNativeScale];
        configuration.minimumFrameInterval = CMTimeMake(1, (int32_t)PNClipRecordingFramesPerSecond);
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
                [completionSelf copyAnimatedImageAtURLToPasteboard:fileURL];
            }
        }];
    }];
}

- (void)toggleRollingRecording:(id)sender {
    NSWindow *targetWindow = [self activeCaptureWindow];
    if (!targetWindow) return;
    NSNumber *windowKey = @((CGWindowID)targetWindow.windowNumber);
    RollingCaptureRecorder *existing = self.rollingRecorders[windowKey];
    CaptureView *view = (CaptureView *)targetWindow.contentView;
    if (existing) {
        [existing stop];
        [self.rollingRecorders removeObjectForKey:windowKey];
        view.rollingRecordingActive = NO;
        self.rollingRecordingItem.state = NSControlStateValueOff;
        return;
    }
    if (self.recorders[windowKey]) {
        NSBeep();
        [self showAlertWithTitle:@"상시 녹화 시작 불가"
                         message:@"일반 녹화를 먼저 중지해 주세요."
                          window:targetWindow];
        return;
    }
    if (![self ensureScreenCaptureAccessForWindow:targetWindow]) return;

    NSRect contentRect = [targetWindow contentRectForFrameRect:targetWindow.frame];
    NSRect recordingRect = NSInsetRect(contentRect, PNClipBorderWidth, PNClipBorderWidth);
    NSScreen *screen = targetWindow.screen ?: NSScreen.mainScreen;
    BOOL usesNativeScale = self.recordingUsesNativeScale;
    RollingCaptureRecorder *recorder = [[RollingCaptureRecorder alloc]
        initWithDestinationFolder:self.saveDirectoryURL
                   filenamePrefix:self.filenamePrefix
                     captureFormat:self.captureFormat];
    self.rollingRecorders[windowKey] = recorder;
    view.rollingRecordingActive = YES;
    self.rollingRecordingItem.state = NSControlStateValueOn;
    [self updateEstimatedGIFSize:nil];
    __weak AppDelegate *weakSelf = self;
    __weak NSWindow *weakWindow = targetWindow;

    [self loadContentFilterForScreen:screen completion:^(SCContentFilter *filter, NSError *error) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.rollingRecorders[windowKey] != recorder) return;
        if (error || !filter) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf.rollingRecorders removeObjectForKey:windowKey];
                ((CaptureView *)weakWindow.contentView).rollingRecordingActive = NO;
                strongSelf.rollingRecordingItem.state = NSControlStateValueOff;
                [strongSelf updateEstimatedGIFSize:nil];
                [strongSelf showAlertWithTitle:@"상시 녹화 실패"
                                       message:error.localizedDescription ?: @"녹화할 디스플레이를 찾을 수 없습니다."
                                        window:weakWindow];
            });
            return;
        }
        SCStreamConfiguration *configuration = [strongSelf configurationForRect:recordingRect
                                                                         onScreen:screen
                                                                   usesNativeScale:usesNativeScale];
        configuration.minimumFrameInterval = CMTimeMake(1, (int32_t)PNClipRecordingFramesPerSecond);
        configuration.queueDepth = 8;
        configuration.pixelFormat = kCVPixelFormatType_32BGRA;
        configuration.showsCursor = NO;
        configuration.capturesAudio = NO;
        [recorder startWithFilter:filter configuration:configuration completion:^(NSError *startError) {
            AppDelegate *completionSelf = weakSelf;
            if (!completionSelf || !startError) return;
            if (completionSelf.rollingRecorders[windowKey] == recorder) {
                [completionSelf.rollingRecorders removeObjectForKey:windowKey];
            }
            ((CaptureView *)weakWindow.contentView).rollingRecordingActive = NO;
            completionSelf.rollingRecordingItem.state = NSControlStateValueOff;
            [completionSelf updateEstimatedGIFSize:nil];
            [completionSelf showAlertWithTitle:@"상시 녹화 실패"
                                       message:startError.localizedDescription
                                        window:weakWindow];
        }];
    }];
}

- (void)saveRollingRecording:(id)sender {
    NSWindow *targetWindow = [self activeCaptureWindow];
    if (!targetWindow) return;
    NSNumber *windowKey = @((CGWindowID)targetWindow.windowNumber);
    RollingCaptureRecorder *recorder = self.rollingRecorders[windowKey];
    if (!recorder) return;
    __weak AppDelegate *weakSelf = self;
    __weak NSWindow *weakWindow = targetWindow;
    [recorder saveRecentGIFWithDuration:self.recordingDuration
                             completion:^(NSURL *fileURL, NSError *error) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            NSBeep();
            [strongSelf showAlertWithTitle:@"최근 구간 저장 실패"
                                   message:error.localizedDescription
                                    window:weakWindow];
        } else if (fileURL) {
            strongSelf.lastCreatedFileURL = fileURL;
            [strongSelf copyAnimatedImageAtURLToPasteboard:fileURL];
        }
    }];
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
    NSNumber *windowKey = window ? @((CGWindowID)window.windowNumber) : nil;
    if (!self.recorders[windowKey] && !self.rollingRecorders[windowKey]) {
        for (NSWindow *candidate in self.windows) {
            NSNumber *candidateKey = @((CGWindowID)candidate.windowNumber);
            if (self.recorders[candidateKey] || self.rollingRecorders[candidateKey]) {
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
    RollingCaptureRecorder *rolling = self.rollingRecorders[windowKey];
    CaptureRecorder *recorder = self.recorders[windowKey];
    unsigned long long bytes = rolling
        ? [rolling estimatedGIFSizeForDuration:self.recordingDuration]
        : [recorder estimatedGIFSize];
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
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    UTType *type = [UTType typeWithFilenameExtension:extension];
    if (type) [item setData:imageData forType:(NSPasteboardType)type.identifier];
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
