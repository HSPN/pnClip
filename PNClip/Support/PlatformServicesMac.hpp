#pragma once
#include "../Core/PlatformServices.hpp"
#include <memory>
namespace pnclip {
[[nodiscard]] std::unique_ptr<StartupBackend> makeStartupBackendMac();
[[nodiscard]] std::unique_ptr<ShellBackend> makeShellBackendMac();
[[nodiscard]] std::unique_ptr<ClipboardBackend> makeClipboardBackendMac();
}
