#include "PlatformServicesWin.hpp"
#include "ImageFilesWin.hpp"
#include <algorithm>
#include <cstring>
#include <shellapi.h>
#include <shlobj.h>
#include <windows.h>

namespace pnclip {
static_assert(platformContractVersion == 1);
namespace {
constexpr auto settingsKey = L"Software\\PNClip";
constexpr auto runKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
std::wstring readString(const wchar_t *key, const wchar_t *name) {
    DWORD bytes = 0;
    if (RegGetValueW(HKEY_CURRENT_USER, key, name, RRF_RT_REG_SZ, nullptr, nullptr, &bytes) != ERROR_SUCCESS)
        return {};
    std::wstring out(bytes / sizeof(wchar_t), L'\0');
    if (RegGetValueW(HKEY_CURRENT_USER, key, name, RRF_RT_REG_SZ, nullptr, out.data(), &bytes) !=
        ERROR_SUCCESS)
        return {};
    while (!out.empty() && out.back() == L'\0')
        out.pop_back();
    return out;
}
DWORD readNumber(const wchar_t *name, DWORD fallback) {
    DWORD value = 0, bytes = sizeof(value);
    return RegGetValueW(HKEY_CURRENT_USER, settingsKey, name, RRF_RT_REG_DWORD, nullptr, &value, &bytes) ==
                   ERROR_SUCCESS
               ? value
               : fallback;
}
void writeString(HKEY key, const wchar_t *name, const std::wstring &text) {
    RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)text.c_str(),
                   (DWORD)((text.size() + 1) * sizeof(wchar_t)));
}
void writeNumber(HKEY key, const wchar_t *name, DWORD value) {
    RegSetValueExW(key, name, 0, REG_DWORD, (const BYTE *)&value, sizeof(value));
}
HGLOBAL fileDrop(const std::filesystem::path &path) {
    auto name = path.wstring();
    auto memory = GlobalAlloc(GHND, sizeof(DROPFILES) + (name.size() + 2) * sizeof(wchar_t));
    if (!memory)
        return nullptr;
    auto *data = (DROPFILES *)GlobalLock(memory);
    if (!data) {
        GlobalFree(memory);
        return nullptr;
    }
    data->pFiles = sizeof(DROPFILES);
    data->fWide = TRUE;
    std::memcpy((BYTE *)data + sizeof(DROPFILES), name.c_str(), (name.size() + 1) * sizeof(wchar_t));
    GlobalUnlock(memory);
    return memory;
}
class ClipboardBackendWin final : public ClipboardBackend {
    HWND owner_ = CreateWindowExW(0, L"STATIC", L"PNClip clipboard", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                  GetModuleHandleW(nullptr), nullptr);

  public:
    ~ClipboardBackendWin() override {
        if (owner_)
            DestroyWindow(owner_);
    }
    bool copyImage(const PixelBuffer &image, CaptureFormat, const std::filesystem::path &path) override {
        if (!image.valid())
            return false;
        const size_t bytes = (size_t)image.width * image.height * 4;
        auto memory = GlobalAlloc(GHND, sizeof(BITMAPV5HEADER) + bytes);
        if (!memory)
            return false;
        auto *header = (BITMAPV5HEADER *)GlobalLock(memory);
        if (!header) {
            GlobalFree(memory);
            return false;
        }
        header->bV5Size = sizeof(*header);
        header->bV5Width = image.width;
        header->bV5Height = -(LONG)image.height;
        header->bV5Planes = 1;
        header->bV5BitCount = 32;
        header->bV5Compression = BI_BITFIELDS;
        header->bV5RedMask = 0x00ff0000;
        header->bV5GreenMask = 0x0000ff00;
        header->bV5BlueMask = 0x000000ff;
        header->bV5AlphaMask = 0xff000000;
        header->bV5CSType = LCS_sRGB;
        header->bV5SizeImage = (DWORD)bytes;
        auto *pixels = (std::byte *)(header + 1);
        for (unsigned y = 0; y < image.height; ++y) {
            std::memcpy(pixels + (size_t)y * image.width * 4, image.bytes.data() + (size_t)y * image.stride,
                        (size_t)image.width * 4);
            if (image.format == PixelFormat::rgba8)
                for (unsigned x = 0; x < image.width; ++x)
                    std::swap(pixels[((size_t)y * image.width + x) * 4],
                              pixels[((size_t)y * image.width + x) * 4 + 2]);
        }
        GlobalUnlock(memory);
        if (!OpenClipboard(owner_)) {
            GlobalFree(memory);
            return false;
        }
        EmptyClipboard();
        bool success = SetClipboardData(CF_DIBV5, memory) != nullptr;
        if (!success)
            GlobalFree(memory);
        if (!path.empty()) {
            auto drop = fileDrop(path);
            if (drop && !SetClipboardData(CF_HDROP, drop))
                GlobalFree(drop);
        }
        CloseClipboard();
        return success;
    }
    bool copyFile(const std::filesystem::path &path) override {
        auto memory = fileDrop(path);
        if (!memory)
            return false;
        if (!OpenClipboard(owner_)) {
            GlobalFree(memory);
            return false;
        }
        EmptyClipboard();
        bool success = SetClipboardData(CF_HDROP, memory) != nullptr;
        if (!success)
            GlobalFree(memory);
        CloseClipboard();
        return success;
    }
};
class StartupBackendWin final : public StartupBackend {
  public:
    bool enabled() const override { return !readString(runKey, L"PNClip").empty(); }
    bool setEnabled(bool enabled) override {
        HKEY key{};
        if (RegCreateKeyExW(HKEY_CURRENT_USER, runKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                            nullptr) != ERROR_SUCCESS)
            return false;
        LSTATUS result;
        if (enabled) {
            std::wstring executable(32768, L'\0');
            executable.resize(GetModuleFileNameW(nullptr, executable.data(), (DWORD)executable.size()));
            auto command = L"\"" + executable + L"\" --tray";
            result = RegSetValueExW(key, L"PNClip", 0, REG_SZ, (const BYTE *)command.c_str(),
                                    (DWORD)((command.size() + 1) * sizeof(wchar_t)));
        } else {
            result = RegDeleteValueW(key, L"PNClip");
        }
        RegCloseKey(key);
        return result == ERROR_SUCCESS || (!enabled && result == ERROR_FILE_NOT_FOUND);
    }
    bool requiresApproval() const override { return false; }
    void openApprovalSettings() override {
        ShellExecuteW(nullptr, L"open", L"ms-settings:startupapps", nullptr, nullptr, SW_SHOWNORMAL);
    }
};
class ShellBackendWin final : public ShellBackend {
  public:
    bool open(const std::filesystem::path &path) override {
        return !path.empty() &&
               (INT_PTR)ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL) > 32;
    }
};
class SettingsBackendWin final : public SettingsBackend {
  public:
    CaptureSettings load() const override {
        CaptureSettings settings;
        auto folder = readString(settingsKey, L"Destination");
        settings.destinationFolder = folder.empty() ? desktopFolder() : std::filesystem::path(folder);
        auto prefix = readString(settingsKey, L"Prefix");
        if (!prefix.empty())
            settings.filenamePrefix = utf8(prefix);
        settings.format = readNumber(L"WebP", 0) ? CaptureFormat::webP : CaptureFormat::pngGif;
        settings.maximumDuration = std::chrono::milliseconds(readNumber(L"Seconds", 5) == 10 ? 10000 : 5000);
        settings.framesPerSecond = 24;
        settings.nativeScale = readNumber(L"NativeScale", 0) != 0;
        return settings;
    }
    void save(const CaptureSettings &settings) override {
        HKEY key{};
        if (RegCreateKeyExW(HKEY_CURRENT_USER, settingsKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                            nullptr) != ERROR_SUCCESS)
            return;
        writeString(key, L"Destination", settings.destinationFolder.wstring());
        writeString(key, L"Prefix", wide(settings.filenamePrefix));
        writeNumber(key, L"WebP", settings.format == CaptureFormat::webP);
        writeNumber(key, L"Seconds", (DWORD)(settings.maximumDuration.count() / 1000));
        writeNumber(key, L"NativeScale", settings.nativeScale);
        RegCloseKey(key);
    }
};
} // namespace
std::unique_ptr<ClipboardBackend> makeClipboardBackendWin() {
    return std::make_unique<ClipboardBackendWin>();
}
std::unique_ptr<StartupBackend> makeStartupBackendWin() { return std::make_unique<StartupBackendWin>(); }
std::unique_ptr<ShellBackend> makeShellBackendWin() { return std::make_unique<ShellBackendWin>(); }
std::unique_ptr<SettingsBackend> makeSettingsBackendWin() { return std::make_unique<SettingsBackendWin>(); }
} // namespace pnclip
