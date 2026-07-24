#import "CaptureRecorder.h"
#import "../Support/PNClipConstants.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation CaptureRecorder {
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

- (instancetype)initWithWindowID:(CGWindowID)windowID destinationFolder:(NSURL *)folder {
    self = [super init];
    if (self) {
        _windowID = windowID;
        _destinationFolder = folder;
        _frames = [NSMutableArray array];
        _ciContext = [CIContext contextWithOptions:nil];
        _captureQueue = dispatch_queue_create("com.example.PNClip.gif-capture", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isRecording {
    @synchronized (self) { return !_finishing; }
}

- (void)startWithFilter:(SCContentFilter *)filter
          configuration:(SCStreamConfiguration *)configuration
            stopHandler:(void (^)(void))stopHandler
             completion:(void (^)(NSURL *, NSError *))completion {
    _completion = [completion copy];
    _stopHandler = [stopHandler copy];
    _stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
    NSError *outputError = nil;
    if (![_stream addStreamOutput:self type:SCStreamOutputTypeScreen
               sampleHandlerQueue:_captureQueue error:&outputError]) {
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
        @synchronized (strongSelf) { strongSelf->_started = YES; }
        if (strongSelf->_stopRequested) {
            [strongSelf stopStream];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(PNClipMaximumRecordingDuration * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf stop]; });
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
            if (error) [strongSelf finishWithURL:nil error:error];
            else [strongSelf encodeGIF];
        });
    }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || _stopRequested || !CMSampleBufferIsValid(sampleBuffer)) return;
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGImageRef frame = [_ciContext createCGImage:image fromRect:image.extent];
    if (frame) [_frames addObject:CFBridgingRelease(frame)];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (!_stopRequested) [self finishWithURL:nil error:error];
}

- (void)encodeGIF {
    if (_frames.count == 0) {
        NSError *error = [NSError errorWithDomain:PNClipErrorDomain code:1
            userInfo:@{NSLocalizedDescriptionKey: @"녹화된 프레임이 없습니다."}];
        [self finishWithURL:nil error:error];
        return;
    }
    NSURL *folder = _destinationFolder ?: [NSFileManager.defaultManager
        URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *destination = PNClipTimestampedFileURL(folder, @"PNClip Recording", @"gif");
    CGImageDestinationRef gif = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)destination, (__bridge CFStringRef)UTTypeGIF.identifier,
        _frames.count, nullptr);
    if (!gif) {
        NSError *error = [NSError errorWithDomain:PNClipErrorDomain code:2
            userInfo:@{NSLocalizedDescriptionKey: @"GIF 파일을 만들 수 없습니다."}];
        [self finishWithURL:nil error:error];
        return;
    }
    NSDictionary *properties = @{(id)kCGImagePropertyGIFDictionary:
        @{(id)kCGImagePropertyGIFLoopCount: @0}};
    CGImageDestinationSetProperties(gif, (__bridge CFDictionaryRef)properties);
    NSUInteger index = 0;
    for (id frame in _frames) {
        NSTimeInterval delay = (index % 6 == 5) ? 0.05 : 0.04;
        NSDictionary *frameProperties = @{(id)kCGImagePropertyGIFDictionary: @{
            (id)kCGImagePropertyGIFDelayTime: @(delay),
            (id)kCGImagePropertyGIFUnclampedDelayTime: @(delay)}};
        CGImageDestinationAddImage(gif, (__bridge CGImageRef)frame,
                                   (__bridge CFDictionaryRef)frameProperties);
        index++;
    }
    BOOL succeeded = CGImageDestinationFinalize(gif);
    CFRelease(gif);
    if (!succeeded) {
        NSError *error = [NSError errorWithDomain:PNClipErrorDomain code:3
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
