#include "../PNClip/Capture/CaptureBackendWin.hpp"
#include "../PNClip/Support/ImageFilesWin.hpp"
#include <atomic>
#include <cassert>
#include <dwmapi.h>
#include <future>
#include <iostream>
#include <thread>
#include <windows.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Security.Authorization.AppCapabilityAccess.h>
#include <winrt/base.h>
using namespace pnclip;
using namespace std::chrono_literals;
namespace {
LRESULT CALLBACK fixtureProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_PAINT) {
        PAINTSTRUCT ps;
        auto dc = BeginPaint(window, &ps);
        RECT r;
        GetClientRect(window, &r);
        auto brush = CreateSolidBrush(RGB(240, 20, 30));
        FillRect(dc, &r, brush);
        DeleteObject(brush);
        EndPaint(window, &ps);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}
void pumpFor(std::chrono::milliseconds duration) {
    auto end = std::chrono::steady_clock::now() + duration;
    while (std::chrono::steady_clock::now() < end) {
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        std::this_thread::sleep_for(5ms);
    }
}
template <class T> T await(std::future<T> &future) {
    auto end = std::chrono::steady_clock::now() + 15s;
    while (future.wait_for(0ms) != std::future_status::ready && std::chrono::steady_clock::now() < end)
        pumpFor(10ms);
    if (future.wait_for(0ms) != std::future_status::ready)
        throw std::runtime_error("Capture callback timed out");
    return future.get();
}
PixelBuffer capture(CaptureBackend &backend, const CaptureTarget &target) {
    std::promise<std::pair<PixelBuffer, ServiceError>> result;
    auto future = result.get_future();
    backend.captureStill(
        target, [&](PixelBuffer image, ServiceError error) { result.set_value({std::move(image), error}); });
    auto [image, error] = await(future);
    if (error.code)
        throw std::runtime_error(error.message);
    assert(image.valid());
    return image;
}
void assertRed(const PixelBuffer &image) {
    auto offset = (size_t)(image.height / 2) * image.stride + (image.width / 2) * 4;
    assert(std::to_integer<int>(image.bytes[offset + 2]) > 200);
    assert(std::to_integer<int>(image.bytes[offset + 1]) < 60);
}
} // namespace
void runCaptureTests() {
    auto borderAccess = std::async(std::launch::async, [] {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        try {
            using namespace winrt::Windows::Graphics::Capture;
            if (winrt::Windows::Foundation::Metadata::ApiInformation::IsPropertyPresent(
                    L"Windows.Graphics.Capture.GraphicsCaptureSession", L"IsBorderRequired")) {
                auto status =
                    GraphicsCaptureAccess::RequestAccessAsync(GraphicsCaptureAccessKind::Borderless).get();
                std::cout << "Borderless capture access: "
                          << (status == winrt::Windows::Security::Authorization::AppCapabilityAccess::
                                            AppCapabilityAccessStatus::Allowed
                                  ? "allowed"
                                  : "denied (system border fallback)")
                          << '\n';
            }
        } catch (const winrt::hresult_error &) {
            std::cout << "Borderless capture unavailable (system border fallback)\n";
        }
        winrt::uninit_apartment();
    });
    borderAccess.get();
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSW cls{};
    cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpfnWndProc = fixtureProc;
    cls.lpszClassName = L"PNClipTestFixture";
    RegisterClassW(&cls);
    auto window =
        CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, cls.lpszClassName, L"PNClip capture test",
                        WS_POPUP | WS_VISIBLE, 100, 100, 160, 120, nullptr, nullptr, cls.hInstance, nullptr);
    if (!window)
        throw std::runtime_error("Test window creation failed");
    UpdateWindow(window);
    pumpFor(200ms);
    auto backend = makeCaptureBackendWin();
    CaptureTarget target;
    target.sessionId = 1;
    target.source = CaptureSource::window;
    target.sourceWindow = (WindowId)(uintptr_t)window;
    target.sourceWindowSize = {0, 0, 160, 120};
    target.nativeScale = true;
    auto image = capture(*backend, target);
    assert(image.width == 160 && image.height == 120);
    assertRed(image);
    target.cropPixels = {20, 10, 64, 48};
    image = capture(*backend, target);
    assert(image.width == 64 && image.height == 48);
    assertRed(image);
    target.cropPixels = {};
    CaptureSettings settings;
    settings.destinationFolder = std::filesystem::current_path() / "test-output";
    settings.maximumDuration = 300ms;
    settings.framesPerSecond = 12;
    std::promise<std::pair<std::filesystem::path, ServiceError>> recorded;
    auto future = recorded.get_future();
    std::atomic<int> callbacks = 0;
    backend->startRecording(target, settings, [&](auto path, auto error) {
        ++callbacks;
        recorded.set_value({path, error});
    });
    assert(backend->isRecording(1));
    auto [path, error] = await(future);
    if (error.code)
        throw std::runtime_error(error.message);
    assert(!path.empty() && std::filesystem::file_size(path) > 30);
    pumpFor(30ms);
    assert(callbacks == 1 && !backend->isRecording(1));
    std::promise<std::pair<std::filesystem::path, ServiceError>> rolling;
    auto rollingFuture = rolling.get_future();
    backend->startRolling(target, settings, [&](auto p, auto e) { rolling.set_value({p, e}); });
    assert(backend->isRolling(1));
    pumpFor(450ms);
    backend->saveRolling(1, 200ms);
    auto saved = await(rollingFuture);
    if (saved.second.code)
        throw std::runtime_error(saved.second.message);
    assert(std::filesystem::exists(saved.first) && backend->isRolling(1));
    backend->stopRolling(1);
    pumpFor(100ms);
    assert(!backend->isRolling(1));
    std::promise<ServiceError> cancelled;
    auto cancelledFuture = cancelled.get_future();
    backend->startRecording(target, settings, [&](auto, auto e) { cancelled.set_value(e); });
    backend->stopRecording(1);
    assert(!await(cancelledFuture).code);
    pumpFor(30ms);
    // A display crop beneath an excluded overlay must contain only the red fixture.
    auto monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof(info)};
    GetMonitorInfoW(monitor, &info);
    auto scale = monitorScaleWin(monitor);
    CaptureTarget display;
    display.sessionId = 2;
    display.displayId = (uint64_t)(uintptr_t)monitor;
    display.nativeScale = true;
    display.captureArea = {(100 - info.rcMonitor.left) / scale, (100 - info.rcMonitor.top) / scale,
                           160 / scale, 120 / scale};
    auto cover = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, L"STATIC", L"EXCLUDED",
                                 WS_POPUP | WS_VISIBLE | SS_WHITERECT, 110, 110, 140, 100, nullptr, nullptr,
                                 cls.hInstance, nullptr);
    assert(SetWindowDisplayAffinity(cover, WDA_EXCLUDEFROMCAPTURE));
    pumpFor(200ms);
    image = capture(*backend, display);
    assert(image.width == 160 && image.height == 120);
    assertRed(image);
    DestroyWindow(cover);
    DestroyWindow(window);
    backend.reset();
    std::cout << "PASS: real window capture, crop, timed GIF recording, rolling save, startup cancellation, "
                 "display crop and overlay exclusion\n";
}
