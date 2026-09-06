#include "AppController.hpp"
#include <utility>
namespace pnclip {
AppController::AppController(CaptureBackend& capture) : capture_(capture) {}
AppController::AppController(CaptureBackend& capture, StartupBackend& startup, ShellBackend& shell)
    : capture_(capture), startup_(&startup), shell_(&shell) {}
AppController::AppController(CaptureBackend& capture, ClipboardBackend& clipboard,
    StartupBackend& startup, ShellBackend& shell)
    : capture_(capture), clipboard_(&clipboard), startup_(&startup), shell_(&shell) {}
AppController::AppController(CaptureBackend& capture, ClipboardBackend& clipboard,
    StartupBackend& startup, ShellBackend& shell, SettingsBackend& settings)
    : capture_(capture), clipboard_(&clipboard), startup_(&startup), shell_(&shell),
      settingsBackend_(&settings), settings_(settings.load()) {}
void AppController::updateSettings(CaptureSettings settings) {
    settings_ = std::move(settings); if (settingsBackend_) settingsBackend_->save(settings_);
}
void AppController::capture(const CaptureTarget& target, StillCaptureCallback callback) {
    if (!target.valid()) {
        if (callback) callback({}, {service_error::invalidArgument, "Invalid capture target"});
        return;
    }
    capture_.captureStill(target, std::move(callback));
}
RecordingToggleResult AppController::toggleRecording(
    const CaptureTarget& target, RecordingCallback callback) {
    if (!target.valid()) return RecordingToggleResult::invalidTarget;
    if (capture_.isRolling(target.sessionId)) {
        capture_.stopRolling(target.sessionId);
        return RecordingToggleResult::stoppedRolling;
    }
    if (capture_.isRecording(target.sessionId)) {
        capture_.stopRecording(target.sessionId);
        return RecordingToggleResult::stopped;
    }
    capture_.startRecording(target, settings_, std::move(callback));
    return RecordingToggleResult::started;
}
void AppController::stopRecording(WindowId id) { capture_.stopRecording(id); }
RecordingToggleResult AppController::toggleRolling(
    const CaptureTarget& target, RecordingCallback callback) {
    if (!target.valid()) return RecordingToggleResult::invalidTarget;
    if (capture_.isRolling(target.sessionId)) {
        capture_.stopRolling(target.sessionId);
        return RecordingToggleResult::stopped;
    }
    if (capture_.isRecording(target.sessionId)) {
        return RecordingToggleResult::blockedByRecording;
    }
    capture_.startRolling(target, settings_, std::move(callback));
    return RecordingToggleResult::started;
}
void AppController::saveRolling(WindowId id, std::chrono::milliseconds duration) {
    capture_.saveRolling(id, duration);
}
void AppController::stopRolling(WindowId id) { capture_.stopRolling(id); }
bool AppController::isRecording(WindowId id) const { return capture_.isRecording(id); }
bool AppController::isRolling(WindowId id) const { return capture_.isRolling(id); }
std::uint64_t AppController::estimatedRecordingSize(WindowId id) const {
    return capture_.estimatedRecordingSize(id);
}
std::uint64_t AppController::estimatedRollingSize(
    WindowId id, std::chrono::milliseconds duration) const {
    return capture_.estimatedRollingSize(id, duration);
}
void AppController::updateFilenamePrefix(const std::string& prefix) {
    settings_.filenamePrefix = prefix;
    capture_.updateFilenamePrefix(prefix);
    if (settingsBackend_) settingsBackend_->save(settings_);
}
bool AppController::setStartupEnabled(bool enabled) { return startup_ && startup_->setEnabled(enabled); }
bool AppController::startupRequiresApproval() const {
    return startup_ && startup_->requiresApproval();
}
void AppController::openStartupApprovalSettings() {
    if (startup_) startup_->openApprovalSettings();
}
bool AppController::open(const std::filesystem::path& path) { return shell_ && shell_->open(path); }
bool AppController::copyFile(const std::filesystem::path& path) {
    return clipboard_ && clipboard_->copyFile(path);
}
}
