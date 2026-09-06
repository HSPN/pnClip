#include "../Core/PlatformCapabilities.hpp"

#include <winrt/Windows.Graphics.Capture.h>

namespace pnclip {

PlatformCapabilities queryPlatformCapabilities() {
    const bool captureSupported =
        winrt::Windows::Graphics::Capture::GraphicsCaptureSession::IsSupported();
    return {
        .screenCapture = captureSupported,
        .windowCapture = captureSupported,
        .uiElementSelection = true,
        .startupActivation = true,
        .platformName = "Windows",
    };
}

}  // namespace pnclip
