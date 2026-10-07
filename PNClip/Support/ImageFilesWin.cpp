#include "ImageFilesWin.hpp"
#include "../Core/GifEncoder.hpp"
#include "../Core/WebPEncoder.hpp"
#include <array>
#include <atomic>
#include <cstring>
#include <iomanip>
#include <shellscalingapi.h>
#include <shlobj.h>
#include <sstream>
#include <wincodec.h>
#include <winrt/base.h>

namespace pnclip {
std::wstring wide(const std::string &text) {
    if (text.empty())
        return {};
    int length = MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0);
    std::wstring out(length, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), length);
    return out;
}
std::string utf8(const std::wstring &text) {
    if (text.empty())
        return {};
    int length = WideCharToMultiByte(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0, nullptr, nullptr);
    std::string out(length, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), length, nullptr, nullptr);
    return out;
}
std::filesystem::path desktopFolder() {
    PWSTR raw{};
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Desktop, 0, nullptr, &raw))) {
        std::filesystem::path path(raw);
        CoTaskMemFree(raw);
        return path;
    }
    return std::filesystem::current_path();
}
double monitorScaleWin(HMONITOR monitor) {
    UINT x = 96, y = 96;
    GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &x, &y);
    return x / 96.0;
}
std::filesystem::path nextCapturePath(const CaptureSettings &settings, bool animated) {
    SYSTEMTIME time{};
    GetLocalTime(&time);
    static std::atomic<unsigned> sequence{};
    auto prefix = wide(settings.filenamePrefix);
    for (auto &c : prefix)
        if (c < 32 || std::wstring(L"<>:\"/\\|?*").find(c) != std::wstring::npos)
            c = L'_';
    if (prefix.empty())
        prefix = L"PNClip";
    if (prefix.size() > 80)
        prefix.resize(80);
    std::wostringstream name;
    name << prefix << L'_' << std::setfill(L'0') << std::setw(4) << time.wYear << std::setw(2) << time.wMonth
         << std::setw(2) << time.wDay << L'_' << std::setw(2) << time.wHour << std::setw(2) << time.wMinute
         << std::setw(2) << time.wSecond << L'_' << std::setw(3) << time.wMilliseconds << L'_'
         << GetCurrentProcessId() << L'_' << sequence++ << L'.'
         << wide(std::string(animated ? animatedImageExtension(settings.format)
                                      : stillImageExtension(settings.format)));
    return (settings.destinationFolder.empty() ? desktopFolder() : settings.destinationFolder) / name.str();
}
static winrt::com_ptr<IWICImagingFactory> factory() {
    return winrt::create_instance<IWICImagingFactory>(CLSID_WICImagingFactory);
}
PixelBuffer resizeImageWin(const PixelBuffer &image, unsigned width, unsigned height) {
    if (width == image.width && height == image.height)
        return image;
    auto wic = factory();
    winrt::com_ptr<IWICBitmap> bitmap;
    winrt::check_hresult(wic->CreateBitmapFromMemory(
        image.width, image.height,
        image.format == PixelFormat::bgra8 ? GUID_WICPixelFormat32bppBGRA : GUID_WICPixelFormat32bppRGBA,
        image.stride, (UINT)image.bytes.size(), (BYTE *)image.bytes.data(), bitmap.put()));
    winrt::com_ptr<IWICBitmapScaler> scaler;
    winrt::check_hresult(wic->CreateBitmapScaler(scaler.put()));
    winrt::check_hresult(scaler->Initialize(bitmap.get(), width, height, WICBitmapInterpolationModeFant));
    PixelBuffer out{width, height, width * 4, image.format,
                    std::vector<std::byte>((size_t)width * height * 4)};
    winrt::check_hresult(
        scaler->CopyPixels(nullptr, out.stride, (UINT)out.bytes.size(), (BYTE *)out.bytes.data()));
    return out;
}
ServiceError saveStillWin(const PixelBuffer &image, const CaptureSettings &settings,
                          std::filesystem::path &path) {
    path.clear();
    if (!image.valid())
        return {service_error::invalidArgument, "Empty image"};
    auto output = nextCapturePath(settings, false);
    auto temporary = output;
    temporary += L".tmp";
    try {
        std::filesystem::create_directories(output.parent_path());
        if (settings.format == CaptureFormat::webP) {
            auto result =
                WebPEncoder{}.encode(std::span(&image, 1), std::array{std::chrono::milliseconds(100)});
            if (!result)
                return {service_error::encoding, result.error.message};
            EncodingError error;
            if (!writeFileAtomically(output, result.data, error))
                return {service_error::io, error.message};
        } else {
            auto wic = factory();
            winrt::com_ptr<IWICStream> stream;
            winrt::check_hresult(wic->CreateStream(stream.put()));
            winrt::check_hresult(stream->InitializeFromFilename(temporary.c_str(), GENERIC_WRITE));
            winrt::com_ptr<IWICBitmapEncoder> encoder;
            winrt::check_hresult(wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.put()));
            winrt::check_hresult(encoder->Initialize(stream.get(), WICBitmapEncoderNoCache));
            winrt::com_ptr<IWICBitmapFrameEncode> frame;
            winrt::check_hresult(encoder->CreateNewFrame(frame.put(), nullptr));
            winrt::check_hresult(frame->Initialize(nullptr));
            winrt::check_hresult(frame->SetSize(image.width, image.height));
            auto format = image.format == PixelFormat::bgra8 ? GUID_WICPixelFormat32bppBGRA
                                                             : GUID_WICPixelFormat32bppRGBA;
            winrt::com_ptr<IWICBitmap> bitmap;
            winrt::check_hresult(wic->CreateBitmapFromMemory(image.width, image.height, format, image.stride,
                                                             (UINT)image.bytes.size(),
                                                             (BYTE *)image.bytes.data(), bitmap.put()));
            winrt::check_hresult(frame->WriteSource(bitmap.get(), nullptr));
            winrt::check_hresult(frame->Commit());
            winrt::check_hresult(encoder->Commit());
            frame = nullptr;
            encoder = nullptr;
            stream = nullptr;
            std::filesystem::rename(temporary, output);
        }
        path = output;
        return {};
    } catch (const winrt::hresult_error &error) {
        std::error_code ignored;
        std::filesystem::remove(temporary, ignored);
        return {service_error::io, winrt::to_string(error.message())};
    } catch (const std::exception &error) {
        std::error_code ignored;
        std::filesystem::remove(temporary, ignored);
        return {service_error::io, error.what()};
    }
}
ServiceError saveAnimationWin(const std::vector<PixelBuffer> &frames,
                              const std::vector<std::chrono::milliseconds> &durations,
                              const CaptureSettings &settings, std::filesystem::path &path) {
    path.clear();
    try {
        auto result = settings.format == CaptureFormat::webP ? WebPEncoder{}.encode(frames, durations)
                                                             : GifEncoder{}.encode(frames, durations);
        if (!result)
            return {service_error::encoding, result.error.message};
        auto output = nextCapturePath(settings, true);
        std::filesystem::create_directories(output.parent_path());
        EncodingError error;
        if (!writeFileAtomically(output, result.data, error))
            return {service_error::io, error.message};
        path = output;
        return {};
    } catch (const std::exception &error) {
        return {service_error::io, error.what()};
    }
}
} // namespace pnclip
