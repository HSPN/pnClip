#include "PlatformServicesWin.hpp"
#include <utility>

namespace pnclip {
static_assert(platformContractVersion == 1);
namespace {
class ClipboardBackendWin final : public ClipboardBackend {
public:
    bool copyImage(const PixelBuffer&, CaptureFormat, const std::filesystem::path&) override {
        return false;
    }
    bool copyFile(const std::filesystem::path&) override { return false; }
};
class StartupBackendWin final : public StartupBackend {
public:
    bool enabled() const override { return false; }
    bool setEnabled(bool) override { return false; }
    bool requiresApproval() const override { return false; }
    void openApprovalSettings() override {}
};
class ShellBackendWin final : public ShellBackend {
public:
    bool open(const std::filesystem::path&) override { return false; }
};
class SettingsBackendWin final : public SettingsBackend {
public:
    CaptureSettings load() const override { return settings_; }
    void save(const CaptureSettings& settings) override { settings_ = settings; }
private:
    CaptureSettings settings_;
};
}

std::unique_ptr<ClipboardBackend> makeClipboardBackendWin() {
    return std::make_unique<ClipboardBackendWin>();
}
std::unique_ptr<StartupBackend> makeStartupBackendWin() {
    return std::make_unique<StartupBackendWin>();
}
std::unique_ptr<ShellBackend> makeShellBackendWin() {
    return std::make_unique<ShellBackendWin>();
}
std::unique_ptr<SettingsBackend> makeSettingsBackendWin() {
    return std::make_unique<SettingsBackendWin>();
}
}
