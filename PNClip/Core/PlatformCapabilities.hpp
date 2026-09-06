#pragma once

#include <string>

namespace pnclip {

struct PlatformCapabilities {
    bool screenCapture{};
    bool windowCapture{};
    bool uiElementSelection{};
    bool startupActivation{};
    std::string platformName;
};

// Implemented once per platform. The build selects either the Mac or Win file;
// the common headers never branch on preprocessor platform macros.
[[nodiscard]] PlatformCapabilities queryPlatformCapabilities();

}  // namespace pnclip
