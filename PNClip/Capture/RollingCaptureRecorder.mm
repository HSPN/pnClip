#import "RollingCaptureRecorder.h"
#import "../Formats/AnimatedImageEncoder.h"
#import "../Formats/GIF/GIFEncoder.h"
#import "../Support/PNClipConstants.h"
#import <CoreImage/CoreImage.h>

static const NSTimeInterval kRollingDuration = 10.0;

@interface RollingFrame : NSObject
@property(nonatomic, strong) id image;
@property(nonatomic) NSTimeInterval startTime;
@property(nonatomic) NSTimeInterval endTime;
@end
@implementation RollingFrame
@end

@implementation RollingCaptureRecorder {
    SCStream *_stream;
    CIContext *_ciContext;
    dispatch_queue_t _captureQueue;
    dispatch_queue_t _encodingQueue;
    NSMutableArray<RollingFrame *> *_frames;
    NSURL *_destinationFolder;
    BOOL _capturing;
    BOOL _stopping;
    NSTimeInterval _latestSampleTime;
    NSTimeInterval _latestSampleUptime;
}

- (instancetype)initWithDestinationFolder:(NSURL *)destinationFolder {
    self = [super init];
    if (self) {
        _destinationFolder = destinationFolder;
        _ciContext = [CIContext contextWithOptions:nil];
        _frames = [NSMutableArray array];
        _captureQueue = dispatch_queue_create("com.example.PNClip.rolling-capture", DISPATCH_QUEUE_SERIAL);
        _encodingQueue = dispatch_queue_create("com.example.PNClip.rolling-encode", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isCapturing { @synchronized (self) { return _capturing && !_stopping; } }

- (void)startWithFilter:(SCContentFilter *)filter
          configuration:(SCStreamConfiguration *)configuration
             completion:(void (^)(NSError *))completion {
    _stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
    NSError *outputError = nil;
    if (![_stream addStreamOutput:self type:SCStreamOutputTypeScreen
               sampleHandlerQueue:_captureQueue error:&outputError]) {
        if (completion) completion(outputError);
        return;
    }
    __weak RollingCaptureRecorder *weakSelf = self;
    [_stream startCaptureWithCompletionHandler:^(NSError *error) {
        RollingCaptureRecorder *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!error) {
            @synchronized (strongSelf) {
                strongSelf->_capturing = !strongSelf->_stopping;
            }
            if (strongSelf->_stopping) [strongSelf->_stream stopCaptureWithCompletionHandler:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || _stopping || !CMSampleBufferIsValid(sampleBuffer)) return;
    NSTimeInterval timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
    if (!isfinite(timestamp)) return;
    _latestSampleTime = timestamp;
    _latestSampleUptime = NSProcessInfo.processInfo.systemUptime;

    SCFrameStatus status = SCFrameStatusComplete;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        NSDictionary *attachment = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
        NSNumber *statusValue = attachment[SCStreamFrameInfoStatus];
        if (statusValue) status = (SCFrameStatus)statusValue.integerValue;
    }

    RollingFrame *previous = _frames.lastObject;
    if (previous) previous.endTime = MAX(previous.endTime, timestamp);
    if (status == SCFrameStatusComplete) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer) {
            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
            CGImageRef image = [_ciContext createCGImage:ciImage fromRect:ciImage.extent];
            if (image) {
                RollingFrame *frame = [[RollingFrame alloc] init];
                frame.image = CFBridgingRelease(image);
                frame.startTime = timestamp;
                frame.endTime = timestamp + 1.0 / PNClipRecordingFramesPerSecond;
                [_frames addObject:frame];
            }
        }
    }
    NSTimeInterval cutoff = timestamp - kRollingDuration;
    while (_frames.count > 1 && _frames.firstObject.endTime <= cutoff) {
        [_frames removeObjectAtIndex:0];
    }
    if (_frames.firstObject.startTime < cutoff) _frames.firstObject.startTime = cutoff;
}

- (void)saveRecentGIFWithDuration:(NSTimeInterval)duration
                       completion:(void (^)(NSURL *, NSError *))completion {
    dispatch_async(_captureQueue, ^{
        if (self->_frames.count == 0) {
            NSError *error = [NSError errorWithDomain:PNClipErrorDomain code:20
                userInfo:@{NSLocalizedDescriptionKey: @"아직 저장할 상시 녹화 프레임이 없습니다."}];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, error); });
            return;
        }
        NSTimeInterval estimatedNow = self->_latestSampleTime +
            MAX(0, NSProcessInfo.processInfo.systemUptime - self->_latestSampleUptime);
        self->_frames.lastObject.endTime = MAX(self->_frames.lastObject.endTime, estimatedNow);
        NSTimeInterval cutoff = estimatedNow - MIN(kRollingDuration, MAX(1.0, duration));
        while (self->_frames.count > 1 && self->_frames.firstObject.endTime <= cutoff) {
            [self->_frames removeObjectAtIndex:0];
        }
        if (self->_frames.firstObject.startTime < cutoff) {
            self->_frames.firstObject.startTime = cutoff;
        }
        NSArray<RollingFrame *> *snapshot = self->_frames.copy;
        dispatch_async(self->_encodingQueue, ^{
            NSMutableArray *images = [NSMutableArray arrayWithCapacity:snapshot.count];
            NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:snapshot.count];
            for (RollingFrame *frame in snapshot) {
                [images addObject:frame.image];
                [durations addObject:@(MAX(0.01, frame.endTime - frame.startTime))];
            }
            NSURL *folder = self->_destinationFolder ?: [NSFileManager.defaultManager
                URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *destination = PNClipTimestampedFileURL(folder, @"PNClip Rolling", @"gif");
            NSError *error = nil;
            GIFEncoder *encoder = [[GIFEncoder alloc] init];
            BOOL success = [encoder encodeFrames:images frameDurations:durations
                                           toURL:destination error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(success ? destination : nil, error);
            });
        });
    });
}

- (unsigned long long)estimatedGIFSizeForDuration:(NSTimeInterval)duration {
    __block unsigned long long result = 0;
    dispatch_sync(_captureQueue, ^{
        if (self->_frames.count == 0) return;
        NSTimeInterval now = self->_latestSampleTime +
            MAX(0, NSProcessInfo.processInfo.systemUptime - self->_latestSampleUptime);
        NSTimeInterval windowDuration = MIN(kRollingDuration, MAX(1.0, duration));
        NSTimeInterval cutoff = now - windowDuration;
        NSUInteger uniqueFrames = 0;
        for (RollingFrame *frame in self->_frames) {
            if (frame.endTime > cutoff) uniqueFrames++;
        }
        RollingFrame *last = self->_frames.lastObject;
        CGImageRef image = (__bridge CGImageRef)last.image;
        double pixelsPerFrame = (double)CGImageGetWidth(image) * CGImageGetHeight(image);
        // Measured screen-content GIFs from the native encoder average near
        // 0.37 encoded bytes per changed pixel. Static frames remain cheap
        // because idle samples are represented as duration, not new images.
        result = (unsigned long long)(pixelsPerFrame * uniqueFrames * 0.37 + 1024.0);
    });
    return result;
}

- (void)stop {
    @synchronized (self) {
        if (_stopping) return;
        _stopping = YES;
        _capturing = NO;
    }
    [_stream stopCaptureWithCompletionHandler:nil];
    dispatch_async(_captureQueue, ^{ [self->_frames removeAllObjects]; });
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    @synchronized (self) { _capturing = NO; }
}
@end
