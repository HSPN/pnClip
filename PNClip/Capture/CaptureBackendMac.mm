#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "CaptureRecorderMac.h"
#import "RollingCaptureRecorderMac.h"
#include "CaptureBackendMac.hpp"
#include <algorithm>
#include <cmath>
#include <mutex>
#include <unordered_set>

namespace pnclip {
namespace {
ServiceError errorFromNSError(NSError *error, int fallback) {
    return {fallback, error ? error.localizedDescription.UTF8String : "Screen capture failed"};
}
PixelBuffer pixelBufferFromImage(CGImageRef image) {
    PixelBuffer result;
    result.width = (uint32_t)CGImageGetWidth(image);
    result.height = (uint32_t)CGImageGetHeight(image);
    result.stride = result.width * 4;
    result.format = PixelFormat::bgra8;
    result.bytes.resize((size_t)result.stride * result.height);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(result.bytes.data(), result.width, result.height,
        8, result.stride, colorSpace,
        (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little));
    CGColorSpaceRelease(colorSpace);
    if (!context) return {};
    CGContextDrawImage(context, CGRectMake(0, 0, result.width, result.height), image);
    CGContextRelease(context);
    return result;
}
class CaptureBackendMac final : public CaptureBackend {
public:
    CaptureBackendMac() : recorders_([NSMutableDictionary dictionary]),
        rolling_([NSMutableDictionary dictionary]), rollingCallbacks_([NSMutableDictionary dictionary]) {}
    ~CaptureBackendMac() override {
        for (CaptureRecorder *recorder in recorders_.allValues) [recorder stop];
        for (RollingCaptureRecorder *recorder in rolling_.allValues) [recorder stop];
        for (NSValue *value in rollingCallbacks_.allValues) {
            delete static_cast<std::shared_ptr<RecordingCallback> *>(value.pointerValue);
        }
    }
    void captureStill(const CaptureTarget& target, StillCaptureCallback callback) override {
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO
            onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content, NSError *error) {
            if (error || !content) { callback({}, errorFromNSError(error, 1)); return; }
            SCContentFilter *filter = nil;
            if (target.source == CaptureSource::window) {
                for (SCWindow *window in content.windows) if (window.windowID == target.sourceWindow) {
                    filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window]; break;
                }
            } else {
                SCDisplay *display = nil;
                for (SCDisplay *candidate in content.displays)
                    if (candidate.displayID == target.displayId) { display = candidate; break; }
                NSMutableArray<SCWindow *> *excluded = [NSMutableArray array];
                for (SCWindow *window in content.windows)
                    if (std::find(target.excludedWindows.begin(), target.excludedWindows.end(),
                                  (WindowId)window.windowID) != target.excludedWindows.end())
                        [excluded addObject:window];
                if (display) filter = [[SCContentFilter alloc] initWithDisplay:display
                    excludingWindows:excluded];
            }
            if (!filter) { callback({}, {2, "Capture target not found"}); return; }
            SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
            const Rect source = target.captureArea;
            if (target.source == CaptureSource::display) configuration.sourceRect = CGRectMake(
                source.x, source.y, source.width, source.height);
            const double width = target.source == CaptureSource::window
                ? target.sourceWindowSize.width : source.width;
            const double height = target.source == CaptureSource::window
                ? target.sourceWindowSize.height : source.height;
            configuration.width = (size_t)llround(width * (target.nativeScale ? target.pixelScale : 1.0));
            configuration.height = (size_t)llround(height * (target.nativeScale ? target.pixelScale : 1.0));
            configuration.showsCursor = NO;
            configuration.backgroundColor = NSColor.clearColor.CGColor;
            if (target.source == CaptureSource::window) {
                if (@available(macOS 14.2, *)) configuration.includeChildWindows = YES;
                if (@available(macOS 14.0, *)) {
                    configuration.ignoreShadowsSingleWindow = !target.cropPixels.empty();
                    configuration.ignoreGlobalClipSingleWindow = YES;
                    configuration.shouldBeOpaque = NO;
                }
            }
            [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
                completionHandler:^(CGImageRef image, NSError *captureError) {
                if (!image || captureError) { callback({}, errorFromNSError(captureError, 3)); return; }
                CGImageRef cropped = image;
                if (!target.cropPixels.empty()) cropped = CGImageCreateWithImageInRect(image,
                    CGRectMake(target.cropPixels.x, target.cropPixels.y,
                               target.cropPixels.width, target.cropPixels.height));
                else CGImageRetain(cropped);
                auto pixels = cropped ? pixelBufferFromImage(cropped) : PixelBuffer{};
                if (cropped) CGImageRelease(cropped);
                const bool valid = pixels.valid();
                callback(std::move(pixels), valid ? ServiceError{} : ServiceError{4, "Pixel conversion failed"});
            }];
        }];
    }
    void startRecording(const CaptureTarget& target, const CaptureSettings& settings,
                        RecordingCallback callback) override {
        {
            std::lock_guard lock(stateMutex_);
            startingRecording_.insert(target.sessionId);
        }
        prepare(target, settings.framesPerSecond, ^(SCContentFilter *filter, SCStreamConfiguration *configuration,
                               CGRect crop, NSError *error) {
            bool cancelled = false;
            {
                std::lock_guard lock(stateMutex_);
                startingRecording_.erase(target.sessionId);
                cancelled = cancelledRecording_.erase(target.sessionId) > 0;
            }
            if (cancelled) { callback({}, {}); return; }
            if (error || !filter) { callback({}, errorFromNSError(error, 10)); return; }
            NSNumber *key = @(target.sessionId);
            NSString *folderPath = [NSString stringWithUTF8String:settings.destinationFolder.string().c_str()];
            NSURL *folder = folderPath.length ? [NSURL fileURLWithPath:folderPath] : nil;
            NSString *prefix = [NSString stringWithUTF8String:settings.filenamePrefix.c_str()];
            auto format = settings.format == CaptureFormat::webP
                ? PNClipCaptureFormatWebP : PNClipCaptureFormatPNGGIF;
            CaptureRecorder *recorder = [[CaptureRecorder alloc]
                initWithWindowID:(CGWindowID)target.sessionId destinationFolder:folder
                maximumDuration:settings.maximumDuration.count() / 1000.0
                filenamePrefix:prefix captureFormat:format cropRect:crop];
            {
                std::lock_guard lock(stateMutex_);
                recorders_[key] = recorder;
            }
            [recorder startWithFilter:filter configuration:configuration stopHandler:nil
                completion:^(NSURL *url, NSError *recordingError) {
                    {
                        std::lock_guard lock(stateMutex_);
                        [recorders_ removeObjectForKey:key];
                    }
                    callback(url ? std::filesystem::path(url.fileSystemRepresentation) : std::filesystem::path{},
                             recordingError ? errorFromNSError(recordingError, 11) : ServiceError{});
                }];
        });
    }
    void stopRecording(WindowId id) override {
        {
            std::lock_guard lock(stateMutex_);
            if (startingRecording_.contains(id)) {
                cancelledRecording_.insert(id);
                return;
            }
        }
        CaptureRecorder *recorder = nil;
        {
            std::lock_guard lock(stateMutex_);
            recorder = recorders_[@(id)];
        }
        [recorder stop];
    }
    void startRolling(const CaptureTarget& target, const CaptureSettings& settings,
                      RecordingCallback callback) override {
        {
            std::lock_guard lock(stateMutex_);
            startingRolling_.insert(target.sessionId);
        }
        prepare(target, settings.framesPerSecond, ^(SCContentFilter *filter, SCStreamConfiguration *configuration,
                               CGRect crop, NSError *error) {
            bool cancelled = false;
            {
                std::lock_guard lock(stateMutex_);
                startingRolling_.erase(target.sessionId);
                cancelled = cancelledRolling_.erase(target.sessionId) > 0;
            }
            if (cancelled) { callback({}, {}); return; }
            if (error || !filter) { callback({}, errorFromNSError(error, 20)); return; }
            NSNumber *key = @(target.sessionId);
            NSString *folderPath = [NSString stringWithUTF8String:settings.destinationFolder.string().c_str()];
            NSURL *folder = folderPath.length ? [NSURL fileURLWithPath:folderPath] : nil;
            NSString *prefix = [NSString stringWithUTF8String:settings.filenamePrefix.c_str()];
            auto format = settings.format == CaptureFormat::webP
                ? PNClipCaptureFormatWebP : PNClipCaptureFormatPNGGIF;
            RollingCaptureRecorder *recorder = [[RollingCaptureRecorder alloc]
                initWithDestinationFolder:folder filenamePrefix:prefix captureFormat:format cropRect:crop];
            auto stored = std::make_shared<RecordingCallback>(std::move(callback));
            {
                std::lock_guard lock(stateMutex_);
                rolling_[key] = recorder;
                rollingCallbacks_[key] = [NSValue valueWithPointer:
                    new std::shared_ptr<RecordingCallback>(stored)];
            }
            [recorder startWithFilter:filter configuration:configuration completion:^(NSError *startError) {
                if (startError) {
                    {
                        std::lock_guard lock(stateMutex_);
                        [rolling_ removeObjectForKey:key];
                        auto *holder = static_cast<std::shared_ptr<RecordingCallback> *>(
                            [rollingCallbacks_[key] pointerValue]);
                        delete holder;
                        [rollingCallbacks_ removeObjectForKey:key];
                    }
                    (*stored)({}, errorFromNSError(startError, 21));
                }
            }];
        });
    }
    void saveRolling(WindowId id, std::chrono::milliseconds duration) override {
        NSNumber *key = @(id);
        RollingCaptureRecorder *recorder = nil;
        std::shared_ptr<RecordingCallback> callback;
        {
            std::lock_guard lock(stateMutex_);
            recorder = rolling_[key];
            auto *holder = static_cast<std::shared_ptr<RecordingCallback> *>(
                [rollingCallbacks_[key] pointerValue]);
            if (holder) callback = *holder;
        }
        if (!recorder || !callback) return;
        [recorder saveRecentGIFWithDuration:duration.count() / 1000.0
            completion:^(NSURL *url, NSError *error) {
                (*callback)(url ? std::filesystem::path(url.fileSystemRepresentation) : std::filesystem::path{},
                            error ? errorFromNSError(error, 22) : ServiceError{});
            }];
    }
    void stopRolling(WindowId id) override {
        {
            std::lock_guard lock(stateMutex_);
            if (startingRolling_.contains(id)) {
                cancelledRolling_.insert(id);
                return;
            }
        }
        NSNumber *key = @(id);
        RollingCaptureRecorder *recorder = nil;
        std::shared_ptr<RecordingCallback> *holder = nullptr;
        {
            std::lock_guard lock(stateMutex_);
            recorder = rolling_[key];
            [rolling_ removeObjectForKey:key];
            holder = static_cast<std::shared_ptr<RecordingCallback> *>(
                [rollingCallbacks_[key] pointerValue]);
            [rollingCallbacks_ removeObjectForKey:key];
        }
        [recorder stop];
        delete holder;
    }
    bool isRecording(WindowId id) const override {
        std::lock_guard lock(stateMutex_);
        return startingRecording_.contains(id) || recorders_[@(id)] != nil;
    }
    bool isRolling(WindowId id) const override {
        std::lock_guard lock(stateMutex_);
        return startingRolling_.contains(id) || rolling_[@(id)] != nil;
    }
    std::uint64_t estimatedRecordingSize(WindowId id) const override {
        std::lock_guard lock(stateMutex_);
        CaptureRecorder *recorder = recorders_[@(id)];
        return recorder ? [recorder estimatedGIFSize] : 0;
    }
    std::uint64_t estimatedRollingSize(WindowId id, std::chrono::milliseconds duration) const override {
        std::lock_guard lock(stateMutex_);
        RollingCaptureRecorder *recorder = rolling_[@(id)];
        return recorder ? [recorder estimatedGIFSizeForDuration:duration.count() / 1000.0] : 0;
    }
    void updateFilenamePrefix(const std::string& prefix) override {
        NSString *value = [NSString stringWithUTF8String:prefix.c_str()];
        std::lock_guard lock(stateMutex_);
        for (CaptureRecorder *recorder in recorders_.allValues) recorder.filenamePrefix = value;
        for (RollingCaptureRecorder *recorder in rolling_.allValues) recorder.filenamePrefix = value;
    }
private:
    using PreparedBlock = void (^)(SCContentFilter *, SCStreamConfiguration *, CGRect, NSError *);
    void prepare(const CaptureTarget& target, std::uint32_t framesPerSecond, PreparedBlock completion) {
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
            completionHandler:^(SCShareableContent *content, NSError *error) {
            if (error || !content) { completion(nil, nil, CGRectZero, error); return; }
            SCContentFilter *filter = nil;
            if (target.source == CaptureSource::window) for (SCWindow *window in content.windows)
                if (window.windowID == target.sourceWindow) {
                    filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window]; break;
                }
            if (target.source == CaptureSource::display) {
                SCDisplay *display = nil;
                for (SCDisplay *item in content.displays) if (item.displayID == target.displayId) { display = item; break; }
                NSMutableArray *excluded = [NSMutableArray array];
                for (SCWindow *window in content.windows)
                    if (std::find(target.excludedWindows.begin(), target.excludedWindows.end(), (WindowId)window.windowID) != target.excludedWindows.end()) [excluded addObject:window];
                if (display) filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:excluded];
            }
            if (!filter) { completion(nil, nil, CGRectZero, nil); return; }
            SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
            if (target.source == CaptureSource::display) configuration.sourceRect = CGRectMake(
                target.captureArea.x, target.captureArea.y,
                target.captureArea.width, target.captureArea.height);
            const double width = target.source == CaptureSource::window
                ? target.sourceWindowSize.width : target.captureArea.width;
            const double height = target.source == CaptureSource::window
                ? target.sourceWindowSize.height : target.captureArea.height;
            configuration.width = llround(width * (target.nativeScale ? target.pixelScale : 1));
            configuration.height = llround(height * (target.nativeScale ? target.pixelScale : 1));
            configuration.showsCursor = NO; configuration.capturesAudio = NO;
            configuration.backgroundColor = NSColor.clearColor.CGColor;
            if (target.source == CaptureSource::window) {
                if (@available(macOS 14.2, *)) configuration.includeChildWindows = YES;
                if (@available(macOS 14.0, *)) {
                    configuration.ignoreShadowsSingleWindow = !target.cropPixels.empty();
                    configuration.ignoreGlobalClipSingleWindow = YES;
                    configuration.shouldBeOpaque = NO;
                }
            }
            configuration.minimumFrameInterval = CMTimeMake(1, std::max<std::uint32_t>(1, framesPerSecond));
            configuration.queueDepth = 8;
            configuration.pixelFormat = kCVPixelFormatType_32BGRA;
            completion(filter, configuration,
                CGRectMake(target.cropPixels.x, target.cropPixels.y,
                           target.cropPixels.width, target.cropPixels.height), nil);
        }];
    }
    __strong NSMutableDictionary<NSNumber *, CaptureRecorder *> *recorders_;
    __strong NSMutableDictionary<NSNumber *, RollingCaptureRecorder *> *rolling_;
    __strong NSMutableDictionary<NSNumber *, NSValue *> *rollingCallbacks_;
    mutable std::mutex stateMutex_;
    std::unordered_set<WindowId> startingRecording_;
    std::unordered_set<WindowId> startingRolling_;
    std::unordered_set<WindowId> cancelledRecording_;
    std::unordered_set<WindowId> cancelledRolling_;
};
}
std::unique_ptr<CaptureBackend> makeCaptureBackendMac() { return std::make_unique<CaptureBackendMac>(); }
}
