#pragma once
#include "PlatformServices.hpp"
namespace pnclip {
enum class RecordingToggleResult : std::uint8_t {
    started,
    stopped,
    stoppedRolling,
    blockedByRecording,
    invalidTarget,
};

class AppController {
public:
    explicit AppController(CaptureBackend&);
    AppController(CaptureBackend&, StartupBackend&, ShellBackend&);
    AppController(CaptureBackend&, ClipboardBackend&, StartupBackend&, ShellBackend&);
    AppController(CaptureBackend&, ClipboardBackend&, StartupBackend&, ShellBackend&, SettingsBackend&);
    [[nodiscard]] const CaptureSettings& settings() const noexcept { return settings_; }
    void updateSettings(CaptureSettings settings);
    void capture(const CaptureTarget&, StillCaptureCallback);
    RecordingToggleResult toggleRecording(const CaptureTarget&, RecordingCallback);
    void stopRecording(WindowId);
    RecordingToggleResult toggleRolling(const CaptureTarget&, RecordingCallback);
    void saveRolling(WindowId, std::chrono::milliseconds);
    void stopRolling(WindowId);
    [[nodiscard]] bool isRecording(WindowId) const;
    [[nodiscard]] bool isRolling(WindowId) const;
    [[nodiscard]] std::uint64_t estimatedRecordingSize(WindowId) const;
    [[nodiscard]] std::uint64_t estimatedRollingSize(WindowId, std::chrono::milliseconds) const;
    void updateFilenamePrefix(const std::string&);
    bool setStartupEnabled(bool);
    [[nodiscard]] bool startupRequiresApproval() const;
    void openStartupApprovalSettings();
    bool open(const std::filesystem::path&);
    bool copyFile(const std::filesystem::path&);
private:
    CaptureBackend& capture_;
    ClipboardBackend* clipboard_{};
    StartupBackend* startup_{};
    ShellBackend* shell_{};
    SettingsBackend* settingsBackend_{};
    CaptureSettings settings_;
};
}
