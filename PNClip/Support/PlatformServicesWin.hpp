#pragma once
#include "../Core/PlatformServices.hpp"
#include <memory>
namespace pnclip {
[[nodiscard]] std::unique_ptr<ClipboardBackend> makeClipboardBackendWin();
[[nodiscard]] std::unique_ptr<StartupBackend> makeStartupBackendWin();
[[nodiscard]] std::unique_ptr<ShellBackend> makeShellBackendWin();
[[nodiscard]] std::unique_ptr<SettingsBackend> makeSettingsBackendWin();
}
