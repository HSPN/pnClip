#import <Foundation/Foundation.h>

@interface GIFLZWEncoder : NSObject
+ (NSData *)encodeIndexedPixels:(NSData *)pixels minimumCodeSize:(uint8_t)minimumCodeSize;
@end
