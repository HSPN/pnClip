#import <Foundation/Foundation.h>

@interface GIFColorQuantizer : NSObject
- (void)addRGBABytes:(const uint8_t *)bytes
               width:(size_t)width
              height:(size_t)height
         bytesPerRow:(size_t)bytesPerRow
          sampleStep:(size_t)sampleStep;
- (NSData *)makePaletteWithColorCount:(NSUInteger)colorCount;
@end
