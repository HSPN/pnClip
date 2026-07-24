#import <AppKit/AppKit.h>

FOUNDATION_EXPORT const CGFloat PNClipBorderWidth;
FOUNDATION_EXPORT const CGFloat PNClipMousePassthroughInset;
FOUNDATION_EXPORT const NSInteger PNClipRecordingFramesPerSecond;
FOUNDATION_EXPORT const NSTimeInterval PNClipMaximumRecordingDuration;
FOUNDATION_EXPORT const NSTimeInterval PNClipCaptureFlashDuration;
FOUNDATION_EXPORT NSString *const PNClipSaveFolderBookmarkKey;
FOUNDATION_EXPORT NSString *const PNClipErrorDomain;

FOUNDATION_EXPORT NSRect PNClipRectBetweenPoints(NSPoint first, NSPoint second);
FOUNDATION_EXPORT NSURL *PNClipTimestampedFileURL(NSURL *folder,
                                                  NSString *prefix,
                                                  NSString *extension);
