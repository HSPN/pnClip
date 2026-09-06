#import <Foundation/Foundation.h>

@interface GIFDitherer : NSObject
- (instancetype)initWithPalette:(NSData *)palette;
- (NSData *)indexedPixelsForRGBABytes:(const uint8_t *)bytes
                                width:(size_t)width
                               height:(size_t)height
                          bytesPerRow:(size_t)bytesPerRow;
@end
