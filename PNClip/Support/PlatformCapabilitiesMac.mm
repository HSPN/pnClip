#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include "../Core/PlatformCapabilities.hpp"

namespace pnclip {

PlatformCapabilities queryPlatformCapabilities() {
    return {
        .screenCapture = true,
        .windowCapture = true,
        .uiElementSelection = true,
        .startupActivation = true,
        .platformName = "macOS",
    };
}

}  // namespace pnclip
