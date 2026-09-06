#pragma once
#include "CaptureTypes.hpp"
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <span>
#include <string>
#include <vector>
namespace pnclip {
inline constexpr std::uint32_t platformContractVersion = 1;

using WindowId = std::uint64_t;

enum class CaptureSource : std::uint8_t {
    display,
    window,
};

// Platform-neutral capture description.
// captureArea is expressed in logical units relative to the selected display's
// top-left corner. sourceWindowSize is a logical size; its x/y are ignored.
// cropPixels is relative to the top-left of the captured output image.
struct CaptureTarget {
    WindowId sessionId{};
    CaptureSource source{CaptureSource::display};
    std::uint64_t displayId{};
    WindowId sourceWindow{};
    Rect captureArea;
    Rect sourceWindowSize;
    Rect cropPixels;
    std::vector<WindowId> excludedWindows;
    bool nativeScale{true};
    double pixelScale{1.0};

    [[nodiscard]] bool valid() const noexcept {
        if (sessionId == 0 || pixelScale <= 0.0) return false;
        if (source == CaptureSource::window) {
            return sourceWindow != 0 && !sourceWindowSize.empty();
        }
        return displayId != 0 && !captureArea.empty();
    }
};
struct ServiceError { int code{}; std::string message; };
namespace service_error {
inline constexpr int invalidArgument = 1;
inline constexpr int unavailable = 2;
inline constexpr int permissionDenied = 3;
inline constexpr int targetNotFound = 4;
inline constexpr int io = 5;
inline constexpr int encoding = 6;
inline constexpr int platformFailure = 1000;
}
using StillCaptureCallback = std::function<void(PixelBuffer, ServiceError)>;
using RecordingCallback = std::function<void(std::filesystem::path, ServiceError)>;
class CaptureBackend {
public:
    virtual ~CaptureBackend() = default;
    virtual void captureStill(const CaptureTarget&, StillCaptureCallback) = 0;
    virtual void startRecording(const CaptureTarget&, const CaptureSettings&, RecordingCallback) = 0;
    virtual void stopRecording(WindowId) = 0;
    virtual void startRolling(const CaptureTarget&, const CaptureSettings&, RecordingCallback) = 0;
    virtual void saveRolling(WindowId, std::chrono::milliseconds) = 0;
    virtual void stopRolling(WindowId) = 0;
    // Active includes asynchronous startup. stop* must also cancel a session
    // that has not finished starting yet. A recording callback fires exactly
    // once; a rolling callback fires once per save or once for a start error.
    [[nodiscard]] virtual bool isRecording(WindowId) const = 0;
    [[nodiscard]] virtual bool isRolling(WindowId) const = 0;
    [[nodiscard]] virtual std::uint64_t estimatedRecordingSize(WindowId) const = 0;
    [[nodiscard]] virtual std::uint64_t estimatedRollingSize(
        WindowId, std::chrono::milliseconds) const = 0;
    virtual void updateFilenamePrefix(const std::string&) = 0;
};
class ClipboardBackend {
public:
    virtual ~ClipboardBackend() = default;
    virtual bool copyImage(const PixelBuffer&, CaptureFormat, const std::filesystem::path&) = 0;
    virtual bool copyFile(const std::filesystem::path&) = 0;
};
class StartupBackend {
public:
    virtual ~StartupBackend() = default;
    [[nodiscard]] virtual bool enabled() const = 0;
    virtual bool setEnabled(bool) = 0;
    [[nodiscard]] virtual bool requiresApproval() const = 0;
    virtual void openApprovalSettings() = 0;
};
class ShellBackend {
public:
    virtual ~ShellBackend() = default;
    virtual bool open(const std::filesystem::path&) = 0;
};
class SettingsBackend {
public:
    virtual ~SettingsBackend() = default;
    [[nodiscard]] virtual CaptureSettings load() const = 0;
    virtual void save(const CaptureSettings&) = 0;
};
}
