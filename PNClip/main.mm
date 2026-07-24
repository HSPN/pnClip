#import <AppKit/AppKit.h>
#import "App/AppDelegate.h"
#import "App/MainMenuBuilder.h"

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
