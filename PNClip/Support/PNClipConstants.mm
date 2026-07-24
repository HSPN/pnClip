#import "PNClipConstants.h"

const CGFloat PNClipBorderWidth = 4.0;
const CGFloat PNClipMousePassthroughInset = 22.0;
const NSInteger PNClipRecordingFramesPerSecond = 24;
const NSTimeInterval PNClipMaximumRecordingDuration = 10.0;
const NSTimeInterval PNClipCaptureFlashDuration = 0.2;
NSString *const PNClipSaveFolderBookmarkKey = @"SaveFolderBookmark";
NSString *const PNClipErrorDomain = @"PNClip";

NSRect PNClipRectBetweenPoints(NSPoint first, NSPoint second) {
    return NSMakeRect(MIN(first.x, second.x),
                      MIN(first.y, second.y),
                      fabs(second.x - first.x),
                      fabs(second.y - first.y));
}

NSURL *PNClipTimestampedFileURL(NSURL *folder, NSString *prefix, NSString *extension) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    NSString *filename = [NSString stringWithFormat:@"%@ %@.%@",
                          prefix, [formatter stringFromDate:NSDate.date], extension];
    return [folder URLByAppendingPathComponent:filename];
}
