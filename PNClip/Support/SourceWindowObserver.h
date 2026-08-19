#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

@interface SourceWindowObserver : NSObject
@property(nonatomic, readonly, getter=isActive) BOOL active;
- (instancetype)initWithProcessID:(pid_t)processID
                            window:(AXUIElementRef)window
                           handler:(void (^)(CFStringRef notification))handler;
@end
