#include "CaptureBackendWin.hpp"

namespace pnclip {
static_assert(platformContractVersion == 1);
namespace {
constexpr ServiceError unavailable() {
    return {service_error::unavailable, "Windows capture adapter is not implemented"};
}

class CaptureBackendWin final : public CaptureBackend {
public:
    void captureStill(const CaptureTarget&, StillCaptureCallback callback) override {
        if (callback) callback({}, unavailable());
    }
    void startRecording(const CaptureTarget&, const CaptureSettings&, RecordingCallback callback) override {
        if (callback) callback({}, unavailable());
    }
    void stopRecording(WindowId) override {}
    void startRolling(const CaptureTarget&, const CaptureSettings&, RecordingCallback callback) override {
        if (callback) callback({}, unavailable());
    }
    void saveRolling(WindowId, std::chrono::milliseconds) override {}
    void stopRolling(WindowId) override {}
    bool isRecording(WindowId) const override { return false; }
    bool isRolling(WindowId) const override { return false; }
    std::uint64_t estimatedRecordingSize(WindowId) const override { return 0; }
    std::uint64_t estimatedRollingSize(WindowId, std::chrono::milliseconds) const override { return 0; }
    void updateFilenamePrefix(const std::string&) override {}
};
}

std::unique_ptr<CaptureBackend> makeCaptureBackendWin() {
    return std::make_unique<CaptureBackendWin>();
}
}
