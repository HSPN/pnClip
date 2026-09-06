#pragma once
#include "../Core/PlatformServices.hpp"
#include <memory>
namespace pnclip {
[[nodiscard]] std::unique_ptr<CaptureBackend> makeCaptureBackendMac();
}
