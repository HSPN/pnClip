#include "../PNClip/Core/CaptureTypes.hpp"
#include "../PNClip/Core/RollingFrameBuffer.hpp"
#include "../PNClip/Core/AppController.hpp"

#include <cassert>
#include <chrono>
#include <cstddef>

using namespace std::chrono_literals;

namespace {
struct CaptureFake : pnclip::CaptureBackend {
    int still{}, recording{}, rolling{};
    pnclip::CaptureTarget lastTarget;
    pnclip::CaptureSettings lastSettings;
    void captureStill(const pnclip::CaptureTarget& target, pnclip::StillCaptureCallback) override {
        ++still; lastTarget = target;
    }
    void startRecording(const pnclip::CaptureTarget& target, const pnclip::CaptureSettings& settings,
                        pnclip::RecordingCallback) override {
        ++recording; lastTarget = target; lastSettings = settings;
    }
    void stopRecording(pnclip::WindowId) override { --recording; }
    void startRolling(const pnclip::CaptureTarget& target, const pnclip::CaptureSettings& settings,
                      pnclip::RecordingCallback) override {
        ++rolling; lastTarget = target; lastSettings = settings;
    }
    void saveRolling(pnclip::WindowId, std::chrono::milliseconds) override {}
    void stopRolling(pnclip::WindowId) override { --rolling; }
    bool isRecording(pnclip::WindowId) const override { return recording > 0; }
    bool isRolling(pnclip::WindowId) const override { return rolling > 0; }
    std::uint64_t estimatedRecordingSize(pnclip::WindowId) const override { return 0; }
    std::uint64_t estimatedRollingSize(pnclip::WindowId, std::chrono::milliseconds) const override { return 0; }
    void updateFilenamePrefix(const std::string&) override {}
};
struct ClipboardFake : pnclip::ClipboardBackend {
    bool copyImage(const pnclip::PixelBuffer&, pnclip::CaptureFormat, const std::filesystem::path&) override { return true; }
    bool copyFile(const std::filesystem::path&) override { return true; }
};
struct StartupFake : pnclip::StartupBackend {
    bool value{}; bool enabled() const override { return value; }
    bool setEnabled(bool next) override { value = next; return true; }
    bool requiresApproval() const override { return false; }
    void openApprovalSettings() override {}
};
struct ShellFake : pnclip::ShellBackend {
    bool open(const std::filesystem::path&) override { return true; }
};
struct SettingsFake : pnclip::SettingsBackend {
    pnclip::CaptureSettings value; pnclip::CaptureSettings load() const override { return value; }
    void save(const pnclip::CaptureSettings& next) override { value = next; }
};
}

static pnclip::CapturedFrame frameAt(std::chrono::steady_clock::time_point time) {
    pnclip::PixelBuffer image{2, 2, 8, pnclip::PixelFormat::rgba8,
                             std::vector<std::byte>(16)};
    return {std::move(image), time};
}

int main() {
    static_assert(pnclip::platformContractVersion == 1);
    const auto rect = pnclip::rectBetween({10, 30}, {4, 12});
    assert(rect.x == 4 && rect.y == 12 && rect.width == 6 && rect.height == 18);
    assert(pnclip::stillImageExtension(pnclip::CaptureFormat::pngGif) == "png");
    assert(pnclip::animatedImageExtension(pnclip::CaptureFormat::webP) == "webp");

    const auto start = std::chrono::steady_clock::now();
    pnclip::RollingFrameBuffer buffer(5s);
    buffer.push(frameAt(start));
    buffer.push(frameAt(start + 4s));
    buffer.push(frameAt(start + 6s));
    assert(buffer.size() == 2);
    assert(buffer.byteSize() == 32);
    assert(buffer.snapshot().front().timestamp == start + 4s);

    CaptureFake capture; ClipboardFake clipboard; StartupFake startup;
    ShellFake shell; SettingsFake settings;
    pnclip::AppController controller(capture, clipboard, startup, shell, settings);
    pnclip::CaptureTarget target;
    target.sessionId = 42;
    target.source = pnclip::CaptureSource::display;
    target.displayId = 7;
    target.captureArea = {10, 20, 640, 480};
    target.pixelScale = 2.0;
    pnclip::CaptureSettings configured;
    configured.framesPerSecond = 30;
    configured.nativeScale = true;
    controller.updateSettings(configured);
    controller.capture(target, {});
    assert(controller.toggleRecording(target, {}) == pnclip::RecordingToggleResult::started);
    assert(controller.toggleRecording(target, {}) == pnclip::RecordingToggleResult::stopped);
    assert(controller.toggleRolling(target, {}) == pnclip::RecordingToggleResult::started);
    assert(controller.toggleRecording(target, {}) == pnclip::RecordingToggleResult::stoppedRolling);
    assert(controller.toggleRecording(target, {}) == pnclip::RecordingToggleResult::started);
    assert(controller.toggleRolling(target, {}) == pnclip::RecordingToggleResult::blockedByRecording);
    assert(controller.toggleRolling({}, {}) == pnclip::RecordingToggleResult::invalidTarget);
    assert(capture.still == 1 && capture.recording == 1 && capture.rolling == 0);
    assert(capture.lastSettings.framesPerSecond == 30);
    assert(capture.isRecording(42));
    controller.stopRecording(42);
    assert(!capture.isRecording(42));
    assert(controller.setStartupEnabled(true) && startup.enabled());
}
