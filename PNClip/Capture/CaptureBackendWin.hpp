#pragma once
#include "../Core/PlatformServices.hpp"
#include <memory>
namespace pnclip {
// The factory is link-complete now. Replace only CaptureBackendWin.cpp when the
// Windows Graphics Capture implementation is added.
[[nodiscard]] std::unique_ptr<CaptureBackend> makeCaptureBackendWin();
}
