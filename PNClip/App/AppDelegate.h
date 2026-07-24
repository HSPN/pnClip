#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "../Capture/CaptureRecorder.h"
#import "../UI/SelectionWindow.h"

@class AccessibilityElementDetector;
@class RollingCaptureRecorder;

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSMutableArray<NSWindow *> *windows;
@property(nonatomic, strong) NSSlider *transparencySlider;
@property(nonatomic, weak) NSWindow *selectedWindow;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMutableArray<SelectionWindow *> *selectionWindows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, CaptureRecorder *> *recorders;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, RollingCaptureRecorder *> *rollingRecorders;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *mousePassthroughWindowIDs;
@property(nonatomic, strong) NSNumber *globalRecordingWindowKey;
@property(nonatomic) CFMachPortRef recordingShortcutTap;
@property(nonatomic) CFRunLoopSourceRef recordingShortcutSource;
@property(nonatomic, strong) NSMenuItem *recordingMouseInputItem;
@property(nonatomic, strong) NSMenuItem *rollingRecordingItem;
@property(nonatomic, strong) NSMenuItem *fiveSecondItem;
@property(nonatomic, strong) NSMenuItem *tenSecondItem;
@property(nonatomic, strong) NSMenuItem *standardScaleItem;
@property(nonatomic, strong) NSMenuItem *retinaScaleItem;
@property(nonatomic, strong) NSMenuItem *estimatedSizeItem;
@property(nonatomic, strong) NSMenuItem *launchAtLoginItem;
@property(nonatomic) BOOL recordingMouseInputEnabled;
@property(nonatomic, strong) id globalMouseMonitor;
@property(nonatomic, strong) id localMouseMonitor;
@property(nonatomic, strong) id localKeyMonitor;
@property(nonatomic, strong) NSTimer *mouseTrackingTimer;
@property(nonatomic, strong) NSTimer *estimatedSizeTimer;
@property(nonatomic, strong) NSURL *saveDirectoryURL;
@property(nonatomic, strong) NSURL *lastCreatedFileURL;
@property(nonatomic) BOOL accessingSecurityScopedDirectory;
@property(nonatomic) NSTimeInterval recordingDuration;
@property(nonatomic) BOOL recordingUsesNativeScale;
@property(nonatomic, strong) AccessibilityElementDetector *elementDetector;

- (void)newWindow:(id)sender;
- (void)createWindowWithFrame:(NSRect)frame;
- (void)closeCurrentWindow:(id)sender;
- (void)closeAllWindows:(id)sender;
- (void)statusItemClicked:(id)sender;
- (void)chooseSaveLocation:(id)sender;
- (void)openMostRecentCapture:(id)sender;
- (void)openSaveDirectory:(id)sender;
- (void)capture:(id)sender;
- (void)toggleRecording:(id)sender;
- (void)toggleRollingRecording:(id)sender;
- (void)saveRollingRecording:(id)sender;
- (void)selectRecordingDuration:(NSMenuItem *)sender;
- (void)selectRecordingScale:(NSMenuItem *)sender;
- (void)updateEstimatedGIFSize:(NSTimer *)timer;
- (void)toggleRecordingMouseInput:(id)sender;
- (void)toggleLaunchAtLogin:(id)sender;
- (void)transparencyChanged:(NSSlider *)sender;
- (void)stopGlobalRecording;
@end
