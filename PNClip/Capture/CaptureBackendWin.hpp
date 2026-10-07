#pragma once
#include "../Core/PlatformServices.hpp"
#include <memory>
namespace pnclip {
// Windows Graphics Capture backend; owns its capture and encoding workers.
[[nodiscard]] std::unique_ptr<CaptureBackend> makeCaptureBackendWin();
}
