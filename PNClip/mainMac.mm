#import <AppKit/AppKit.h>
#import "App/AppDelegateMac.h"
#import "App/MainMenuBuilderMac.h"

int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        application.mainMenu = PNClipCreateMainMenu(delegate);
        [application run];
    }
    return 0;
}
