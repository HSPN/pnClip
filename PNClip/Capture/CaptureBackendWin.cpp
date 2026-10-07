#include "CaptureBackendWin.hpp"
#include "../Support/ImageFilesWin.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <d3d11.h>
#include <deque>
#include <dxgi1_2.h>
#include <future>
#include <map>
#include <mutex>
#include <thread>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Security.Authorization.AppCapabilityAccess.h>

namespace pnclip {
static_assert(platformContractVersion == 1);
namespace {
using namespace std::chrono_literals;
using Clock = std::chrono::steady_clock;
using namespace winrt::Windows::Graphics;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;
constexpr size_t memoryLimit = 512ull * 1024 * 1024;
struct Cancelled {};
struct Apartment {
    Apartment() { winrt::init_apartment(winrt::apartment_type::multi_threaded); }
    ~Apartment() { winrt::uninit_apartment(); }
};

void configureCaptureBorder(const GraphicsCaptureSession &session) {
    // Region capture uses a monitor item, so the default system border surrounds
    // the entire display. Request permission before starting to avoid that flash.
    // Older Windows versions or denied access keep the system's default border.
    try {
        if (winrt::Windows::Foundation::Metadata::ApiInformation::IsPropertyPresent(
                L"Windows.Graphics.Capture.GraphicsCaptureSession", L"IsBorderRequired")) {
            auto access =
                GraphicsCaptureAccess::RequestAccessAsync(GraphicsCaptureAccessKind::Borderless).get();
            if (access == winrt::Windows::Security::Authorization::AppCapabilityAccess::
                              AppCapabilityAccessStatus::Allowed)
                session.IsBorderRequired(false);
        }
    } catch (const winrt::hresult_error &) {
        OutputDebugStringW(L"PNClip: borderless capture unavailable; keeping the system capture border.\n");
    }
}

class CaptureStream {
    winrt::com_ptr<ID3D11Device> device_;
    winrt::com_ptr<ID3D11DeviceContext> context_;
    winrt::com_ptr<ID3D11Texture2D> staging_;
    GraphicsCaptureItem item_{nullptr};
    Direct3D11CaptureFramePool pool_{nullptr};
    GraphicsCaptureSession session_{nullptr};
    SizeInt32 size_{};
    CaptureTarget target_;
    double scale_ = 1;
    PixelBuffer last_;

  public:
    explicit CaptureStream(const CaptureTarget &target) : target_(target) {
        if (!target.valid())
            throw std::runtime_error("Invalid capture target");
        if (!GraphicsCaptureSession::IsSupported())
            throw std::runtime_error("Windows Graphics Capture is unavailable on this system");
        auto interop = winrt::get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        if (target.source == CaptureSource::window) {
            HWND window = (HWND)(uintptr_t)target.sourceWindow;
            if (!IsWindow(window) || IsIconic(window))
                throw std::runtime_error("The source window is closed or minimized");
            scale_ = GetDpiForWindow(window) / 96.0;
            winrt::check_hresult(interop->CreateForWindow(window, winrt::guid_of<GraphicsCaptureItem>(),
                                                          winrt::put_abi(item_)));
        } else {
            auto monitor = (HMONITOR)(uintptr_t)target.displayId;
            scale_ = monitorScaleWin(monitor);
            winrt::check_hresult(interop->CreateForMonitor(monitor, winrt::guid_of<GraphicsCaptureItem>(),
                                                           winrt::put_abi(item_)));
        }
        auto result =
            D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                              nullptr, 0, D3D11_SDK_VERSION, device_.put(), nullptr, context_.put());
        if (FAILED(result))
            winrt::check_hresult(
                D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                  nullptr, 0, D3D11_SDK_VERSION, device_.put(), nullptr, context_.put()));
        auto dxgi = device_.as<IDXGIDevice>();
        winrt::com_ptr<IInspectable> inspectable;
        winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
        size_ = item_.Size();
        pool_ = Direct3D11CaptureFramePool::CreateFreeThreaded(
            inspectable.as<IDirect3DDevice>(), DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size_);
        session_ = pool_.CreateCaptureSession(item_);
        session_.IsCursorCaptureEnabled(true);
        configureCaptureBorder(session_);
        session_.StartCapture();
    }
    ~CaptureStream() {
        if (session_)
            session_.Close();
        if (pool_)
            pool_.Close();
    }
    PixelBuffer frame(const std::atomic<bool> &stopped) {
        if (target_.source == CaptureSource::window && (!IsWindow((HWND)(uintptr_t)target_.sourceWindow) ||
                                                        IsIconic((HWND)(uintptr_t)target_.sourceWindow)))
            throw std::runtime_error("The source window was closed or minimized");
        Direct3D11CaptureFrame frame{nullptr};
        const auto deadline = Clock::now() + 3s;
        do {
            if (stopped)
                throw Cancelled{};
            frame = pool_.TryGetNextFrame();
            if (frame)
                break;
            if (last_.valid())
                return last_;
            std::this_thread::sleep_for(5ms);
        } while (Clock::now() < deadline);
        if (!frame)
            throw std::runtime_error("No capture frame arrived. Restore the source window and try again.");
        if (frame.ContentSize().Width != size_.Width || frame.ContentSize().Height != size_.Height)
            throw std::runtime_error("The source size changed during capture. Start a new recording.");
        auto access =
            frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        winrt::com_ptr<ID3D11Texture2D> texture;
        winrt::check_hresult(access->GetInterface(__uuidof(ID3D11Texture2D), texture.put_void()));
        D3D11_TEXTURE2D_DESC description{};
        texture->GetDesc(&description);
        if (!staging_) {
            description.Usage = D3D11_USAGE_STAGING;
            description.BindFlags = 0;
            description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            description.MiscFlags = 0;
            winrt::check_hresult(device_->CreateTexture2D(&description, nullptr, staging_.put()));
        }
        context_->CopyResource(staging_.get(), texture.get());
        Rect crop{0, 0, (double)size_.Width, (double)size_.Height};
        if (target_.source == CaptureSource::display) {
            crop = {target_.captureArea.x * scale_, target_.captureArea.y * scale_,
                    target_.captureArea.width * scale_, target_.captureArea.height * scale_};
        } else if (!target_.cropPixels.empty())
            crop = target_.cropPixels;
        const int left = (int)std::lround(crop.x), top = (int)std::lround(crop.y);
        const int width = (int)std::lround(crop.width), height = (int)std::lround(crop.height);
        if (left < 0 || top < 0 || width <= 0 || height <= 0 || left + width > size_.Width ||
            top + height > size_.Height)
            throw std::runtime_error("Keep the capture area inside a single display or source window");
        PixelBuffer image{(unsigned)width, (unsigned)height, (unsigned)width * 4, PixelFormat::bgra8,
                          std::vector<std::byte>((size_t)width * height * 4)};
        D3D11_MAPPED_SUBRESOURCE mapped{};
        winrt::check_hresult(context_->Map(staging_.get(), 0, D3D11_MAP_READ, 0, &mapped));
        for (int y = 0; y < height; ++y)
            std::memcpy(image.bytes.data() + (size_t)y * image.stride,
                        (BYTE *)mapped.pData + (size_t)(y + top) * mapped.RowPitch + (size_t)left * 4,
                        image.stride);
        context_->Unmap(staging_.get(), 0);
        frame.Close();
        if (!target_.nativeScale && scale_ != 1)
            image = resizeImageWin(image, std::max(1u, (unsigned)std::lround(width / scale_)),
                                   std::max(1u, (unsigned)std::lround(height / scale_)));
        last_ = image;
        return image;
    }
};
struct Session {
    std::atomic<bool> stop{false}, active{true};
    bool rolling = false;
    std::atomic<long long> saveDuration{0};
    std::atomic<size_t> bytes{0};
    RecordingCallback callback;
    std::jthread thread;
};
struct StillJob {
    std::atomic<bool> stop{false}, done{false};
    std::jthread thread;
};
ServiceError currentError() {
    try {
        throw;
    } catch (const winrt::hresult_error &error) {
        return {service_error::platformFailure, winrt::to_string(error.message())};
    } catch (const std::exception &error) {
        return {service_error::platformFailure, error.what()};
    } catch (...) {
        return {service_error::platformFailure, "Capture failed"};
    }
}
void deliver(const RecordingCallback &callback, const std::filesystem::path &path, ServiceError error) {
    if (callback)
        callback(path, std::move(error));
}
void encodeFrames(std::vector<CapturedFrame> captured, CaptureSettings settings, RecordingCallback callback) {
    std::filesystem::path path;
    ServiceError error;
    try {
        std::vector<PixelBuffer> frames;
        std::vector<std::chrono::milliseconds> durations;
        for (size_t i = 0; i < captured.size(); ++i) {
            durations.push_back(i + 1 < captured.size()
                                    ? std::max(1ms, std::chrono::duration_cast<std::chrono::milliseconds>(
                                                        captured[i + 1].timestamp - captured[i].timestamp))
                                    : std::chrono::milliseconds(1000 / settings.framesPerSecond));
            frames.push_back(std::move(captured[i].image));
        }
        error = saveAnimationWin(frames, durations, settings, path);
    } catch (...) {
        error = currentError();
    }
    deliver(callback, path, error);
}
class CaptureBackendWin final : public CaptureBackend {
    mutable std::mutex mutex_;
    std::map<WindowId, std::shared_ptr<Session>> sessions_;
    std::vector<std::unique_ptr<StillJob>> stills_;
    std::string prefix_;
    std::shared_ptr<Session> find(WindowId id) const {
        std::lock_guard lock(mutex_);
        auto found = sessions_.find(id);
        return found == sessions_.end() ? nullptr : found->second;
    }
    CaptureSettings updated(CaptureSettings settings) {
        std::lock_guard lock(mutex_);
        if (!prefix_.empty())
            settings.filenamePrefix = prefix_;
        return settings;
    }
    void start(const CaptureTarget &target, const CaptureSettings &settings, RecordingCallback callback,
               bool rolling) {
        if (!target.valid() || settings.framesPerSecond < 1 || settings.framesPerSecond > 60 ||
            settings.maximumDuration <= 0ms) {
            deliver(callback, {}, {service_error::invalidArgument, "Invalid recording settings"});
            return;
        }
        auto previous = find(target.sessionId);
        if (previous && previous->active) {
            deliver(callback, {}, {service_error::unavailable, "This area is already recording"});
            return;
        }
        // Join an earlier completed session before replacing its owning thread.
        if (previous && previous->thread.joinable())
            previous->thread.join();
        auto state = std::make_shared<Session>();
        state->rolling = rolling;
        state->callback = callback;
        {
            std::lock_guard lock(mutex_);
            sessions_[target.sessionId] = state;
        }
        state->thread = std::jthread([this, state, target, settings, callback] {
            std::deque<CapturedFrame> frames;
            std::future<void> encoding;
            ServiceError error;
            try {
                Apartment apartment;
                {
                    CaptureStream stream(target);
                    auto startTime = Clock::now();
                    auto next = startTime;
                    const auto interval = std::chrono::microseconds(1000000 / settings.framesPerSecond);
                    while (!state->stop) {
                        auto image = stream.frame(state->stop);
                        auto now = Clock::now();
                        if (frames.empty()) {
                            startTime = now;
                            auto expected =
                                (size_t)(settings.maximumDuration.count() * settings.framesPerSecond / 1000 +
                                         2);
                            if (image.bytes.size() > memoryLimit / expected)
                                throw std::runtime_error(
                                    "Recording exceeds the 512 MB buffer limit. Choose a smaller area, "
                                    "standard resolution, or 5 seconds.");
                        }
                        state->bytes += image.bytes.size();
                        frames.push_back({std::move(image), now});
                        if (state->rolling)
                            while (frames.size() > 1 &&
                                   now - frames.front().timestamp > settings.maximumDuration) {
                                state->bytes -= frames.front().image.bytes.size();
                                frames.pop_front();
                            }
                        auto duration = state->saveDuration.exchange(0);
                        if (duration > 0) {
                            if (encoding.valid() && encoding.wait_for(0ms) != std::future_status::ready)
                                deliver(
                                    callback, {},
                                    {service_error::unavailable, "The previous clip is still being saved"});
                            else {
                                if (encoding.valid())
                                    encoding.get();
                                std::vector<CapturedFrame> snapshot;
                                for (auto &frame : frames)
                                    if (now - frame.timestamp <= std::chrono::milliseconds(duration))
                                        snapshot.push_back(frame);
                                encoding = std::async(std::launch::async, encodeFrames, std::move(snapshot),
                                                      updated(settings), callback);
                            }
                        }
                        if (!state->rolling && now - startTime + interval >= settings.maximumDuration)
                            break;
                        next += interval;
                        if (next < Clock::now())
                            next = Clock::now();
                        while (!state->stop && Clock::now() < next)
                            std::this_thread::sleep_for(2ms);
                    }
                }
            } catch (const Cancelled &) {
            } catch (...) {
                error = currentError();
            }
            if (state->rolling) {
                if (error.code)
                    deliver(callback, {}, error);
                if (state->saveDuration.exchange(0) > 0)
                    deliver(callback, {},
                            {service_error::unavailable, "Rolling capture stopped before saving"});
                if (encoding.valid())
                    encoding.wait();
            } else {
                if (error.code)
                    deliver(callback, {}, error);
                else if (frames.empty())
                    deliver(callback, {}, {});
                else
                    encodeFrames(std::vector<CapturedFrame>(std::make_move_iterator(frames.begin()),
                                                            std::make_move_iterator(frames.end())),
                                 updated(settings), callback);
            }
            state->bytes = 0;
            state->active = false;
        });
    }

  public:
    ~CaptureBackendWin() override {
        for (auto &[id, state] : sessions_)
            state->stop = true;
        for (auto &job : stills_)
            job->stop = true;
        for (auto &[id, state] : sessions_)
            if (state->thread.joinable())
                state->thread.join();
        for (auto &job : stills_)
            if (job->thread.joinable())
                job->thread.join();
    }
    void captureStill(const CaptureTarget &target, StillCaptureCallback callback) override {
        std::erase_if(stills_, [](const auto &job) { return job->done.load(); });
        auto job = std::make_unique<StillJob>();
        auto *state = job.get();
        job->thread = std::jthread([state, target, callback] {
            PixelBuffer image;
            ServiceError error;
            try {
                Apartment apartment;
                {
                    CaptureStream stream(target);
                    image = stream.frame(state->stop);
                }
            } catch (const Cancelled &) {
            } catch (...) {
                error = currentError();
            }
            if (callback)
                callback(std::move(image), error);
            state->done = true;
        });
        stills_.push_back(std::move(job));
    }
    void startRecording(const CaptureTarget &target, const CaptureSettings &settings,
                        RecordingCallback callback) override {
        start(target, settings, std::move(callback), false);
    }
    void startRolling(const CaptureTarget &target, const CaptureSettings &settings,
                      RecordingCallback callback) override {
        start(target, settings, std::move(callback), true);
    }
    void stopRecording(WindowId id) override {
        if (auto state = find(id); state && !state->rolling)
            state->stop = true;
    }
    void stopRolling(WindowId id) override {
        if (auto state = find(id); state && state->rolling)
            state->stop = true;
    }
    void saveRolling(WindowId id, std::chrono::milliseconds duration) override {
        auto state = find(id);
        if (!state || !state->rolling || !state->active || state->stop)
            return;
        long long expected = 0;
        if (duration <= 0ms || !state->saveDuration.compare_exchange_strong(expected, duration.count()))
            deliver(state->callback, {}, {service_error::unavailable, "A clip save is already pending"});
    }
    bool isRecording(WindowId id) const override {
        auto state = find(id);
        return state && !state->rolling && state->active;
    }
    bool isRolling(WindowId id) const override {
        auto state = find(id);
        return state && state->rolling && state->active;
    }
    std::uint64_t estimatedRecordingSize(WindowId id) const override {
        auto state = find(id);
        return state ? state->bytes.load() / 8 : 0;
    }
    std::uint64_t estimatedRollingSize(WindowId id, std::chrono::milliseconds) const override {
        return estimatedRecordingSize(id);
    }
    void updateFilenamePrefix(const std::string &prefix) override {
        std::lock_guard lock(mutex_);
        prefix_ = prefix;
    }
};
} // namespace
std::unique_ptr<CaptureBackend> makeCaptureBackendWin() { return std::make_unique<CaptureBackendWin>(); }
} // namespace pnclip
