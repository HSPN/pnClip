#import "SourceWindowObserver.h"

@interface SourceWindowObserver ()
@property(nonatomic, copy) void (^handler)(CFStringRef notification);
@end

static void SourceWindowObserverCallback(AXObserverRef observer,
                                         AXUIElementRef element,
                                         CFStringRef notification,
                                         void *refcon) {
    (void)observer;
    (void)element;
    SourceWindowObserver *tracker = (__bridge SourceWindowObserver *)refcon;
    if (tracker.handler) tracker.handler(notification);
}

@implementation SourceWindowObserver {
    AXObserverRef _observer;
    AXUIElementRef _window;
    BOOL _active;
}

- (instancetype)initWithProcessID:(pid_t)processID
                            window:(AXUIElementRef)window
                           handler:(void (^)(CFStringRef notification))handler {
    self = [super init];
    if (!self || !window) return self;
    _window = (AXUIElementRef)CFRetain(window);
    self.handler = handler;
    if (AXObserverCreate(processID, SourceWindowObserverCallback, &_observer) != kAXErrorSuccess) {
        return self;
    }

    NSArray *notifications = @[
        (__bridge NSString *)kAXMovedNotification,
        (__bridge NSString *)kAXResizedNotification,
        (__bridge NSString *)kAXWindowMiniaturizedNotification,
        (__bridge NSString *)kAXWindowDeminiaturizedNotification,
        (__bridge NSString *)kAXUIElementDestroyedNotification,
    ];
    BOOL registered = NO;
    for (NSString *notification in notifications) {
        AXError error = AXObserverAddNotification(_observer, _window,
                                                   (__bridge CFStringRef)notification,
                                                   (__bridge void *)self);
        registered = registered || error == kAXErrorSuccess || error == kAXErrorNotificationAlreadyRegistered;
    }
    if (registered) {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(_observer), kCFRunLoopCommonModes);
        _active = YES;
    }
    return self;
}

- (BOOL)isActive { return _active; }

- (void)dealloc {
    if (_observer) {
        if (_active) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(_observer), kCFRunLoopCommonModes);
        }
        CFRelease(_observer);
    }
    if (_window) CFRelease(_window);
}
@end
