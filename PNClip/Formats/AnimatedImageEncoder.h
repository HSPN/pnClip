#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@protocol AnimatedImageEncoder <NSObject>
- (BOOL)encodeFrames:(NSArray *)frames
               toURL:(NSURL *)destinationURL
           frameRate:(NSUInteger)frameRate
               error:(NSError **)error;
@end
