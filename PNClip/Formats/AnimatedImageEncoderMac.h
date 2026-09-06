#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@protocol AnimatedImageEncoder <NSObject>
- (BOOL)encodeFrames:(NSArray *)frames
      frameDurations:(NSArray<NSNumber *> *)frameDurations
               toURL:(NSURL *)destinationURL
               error:(NSError **)error;
@end
