#include "Capture/CaptureBackendWin.hpp"
#include "Core/AppController.hpp"
#include "Support/ImageFilesWin.hpp"
#include "Support/PlatformServicesWin.hpp"
#include <algorithm>
#include <cmath>
#include <commctrl.h>
#include <dwmapi.h>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <oleacc.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <sstream>
#include <uiautomation.h>
#include <windows.h>
#include <windowsx.h>
#include <winrt/base.h>
using namespace pnclip;
using namespace std::chrono_literals;
namespace {
constexpr UINT trayMessage = WM_APP + 1, dispatchMessage = WM_APP + 2;
constexpr COLORREF transparent = RGB(255, 0, 255);
constexpr int edge = 4, header = edge;
constexpr int windowCommandBase = 1000;
enum Command {
    New = 100,
    Select,
    Still,
    Record,
    Rolling,
    SaveRecent,
    Close,
    CloseAll,
    Detach,
    OpenLast,
    OpenFolder,
    Folder,
    Prefix,
    PngGif,
    WebP,
    Five,
    Ten,
    Standard,
    Native,
    PassThrough,
    Opacity20,
    Opacity50,
    Opacity80,
    Transparency,
    Licenses,
    Startup,
    Help,
    Quit
};
struct Overlay {
    HWND window{}, fill{}, source{}, handle{};
    RECT relative{};
    bool element = false, pass = false;
    BYTE opacity = 51;
    int appliedOpacity = -1;
    COLORREF appliedColor = CLR_INVALID;
    WindowId id{};
    ULONGLONG flashUntil{};
};
struct App {
    HINSTANCE instance{};
    HWND hub{}, selector{}, prefixWindow{}, prefixEdit{}, opacityWindow{}, opacitySlider{}, opacityTarget{},
        licenseWindow{};
    std::unique_ptr<CaptureBackend> capture = makeCaptureBackendWin();
    std::unique_ptr<ClipboardBackend> clipboard = makeClipboardBackendWin();
    std::unique_ptr<StartupBackend> startup = makeStartupBackendWin();
    std::unique_ptr<ShellBackend> shell = makeShellBackendWin();
    std::unique_ptr<SettingsBackend> settings = makeSettingsBackendWin();
    AppController controller{*capture, *clipboard, *startup, *shell, *settings};
    std::map<HWND, std::unique_ptr<Overlay>> overlays;
    HWND selected{};
    std::vector<WindowId> menuWindows;
    WindowId nextId = 1;
    std::filesystem::path last;
    std::mutex queueMutex;
    std::vector<std::function<void()>> queue;
    bool closing = false, dragging = false, trayRegistered = false;
    POINT dragStart{};
    RECT preview{};
    HWND previewSource{};
    bool previewElement = false;
    NOTIFYICONDATAW tray{};
    HICON traySymbol{};
    UINT taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    ULONGLONG lastTrayUpdate = 0;
    winrt::com_ptr<IUIAutomation> automation;
    ~App() {
        {
            std::lock_guard lock(queueMutex);
            closing = true;
        }
        capture.reset();
        if (trayRegistered)
            Shell_NotifyIconW(NIM_DELETE, &tray);
        if (traySymbol)
            DestroyIcon(traySymbol);
    }
    void post(std::function<void()> action) {
        std::lock_guard lock(queueMutex);
        if (closing)
            return;
        queue.push_back(std::move(action));
        PostMessageW(hub, dispatchMessage, 0, 0);
    }
    void drain() {
        std::vector<std::function<void()>> actions;
        {
            std::lock_guard lock(queueMutex);
            actions.swap(queue);
        }
        for (auto &action : actions)
            action();
    }
    Overlay *current() {
        auto found = overlays.find(selected);
        return found == overlays.end() ? nullptr : found->second.get();
    }
    bool active(const Overlay *item) {
        return item && (controller.isRecording(item->id) || controller.isRolling(item->id));
    }
    bool anyActive() {
        for (auto &[hwnd, item] : overlays)
            if (active(item.get()))
                return true;
        return false;
    }
    void message(const std::wstring &text, bool error = false) {
        MessageBoxW(current() ? selected : hub, text.c_str(), L"PNClip",
                    MB_OK | (error ? MB_ICONERROR : MB_ICONINFORMATION));
    }
    void notify(const std::wstring &title, const std::wstring &text) {
        tray.uFlags = NIF_INFO;
        tray.dwInfoFlags = NIIF_INFO;
        wcsncpy_s(tray.szInfoTitle, title.c_str(), _TRUNCATE);
        wcsncpy_s(tray.szInfo, text.c_str(), _TRUNCATE);
        Shell_NotifyIconW(NIM_MODIFY, &tray);
    }
} *app{};
RECT windowBounds(HWND window) {
    RECT r{};
    if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof(r))))
        GetWindowRect(window, &r);
    return r;
}
RECT contentBounds(HWND window) {
    RECT r{};
    GetWindowRect(window, &r);
    r.left += edge;
    r.top += header;
    r.right -= edge;
    r.bottom -= edge;
    return r;
}
void showIfChanged(HWND window, bool visible) {
    if (bool(GetWindowLongPtrW(window, GWL_STYLE) & WS_VISIBLE) != visible)
        ShowWindow(window, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
}
void positionIfChanged(HWND window, const RECT &desired) {
    RECT current{};
    GetWindowRect(window, &current);
    if (!EqualRect(&current, &desired))
        SetWindowPos(window, nullptr, desired.left, desired.top, desired.right - desired.left,
                     desired.bottom - desired.top, SWP_NOACTIVATE | SWP_NOZORDER);
}
COLORREF overlayColor(const Overlay &item) {
    return app->controller.isRolling(item.id)                                           ? RGB(240, 31, 31)
           : app->controller.isRecording(item.id) || GetTickCount64() < item.flashUntil ? RGB(255, 122, 20)
                                                                                        : RGB(41, 163, 255);
}
void updateFill(Overlay &item) {
    auto r = contentBounds(item.window);
    positionIfChanged(item.fill, r);
    bool pass = item.source || (item.pass && app->active(&item));
    auto style = GetWindowLongPtrW(item.fill, GWL_EXSTYLE);
    auto desiredStyle = pass ? style | WS_EX_TRANSPARENT : style & ~WS_EX_TRANSPARENT;
    if (style != desiredStyle)
        SetWindowLongPtrW(item.fill, GWL_EXSTYLE, desiredStyle);
    if (item.appliedOpacity != item.opacity) {
        SetLayeredWindowAttributes(item.fill, 0, item.opacity, LWA_ALPHA);
        item.appliedOpacity = item.opacity;
    }
    if (item.handle) {
        RECT outer{};
        GetWindowRect(item.window, &outer);
        const auto dpi = GetDpiForWindow(item.window);
        positionIfChanged(item.handle, {outer.right, outer.top, outer.right + MulDiv(14, dpi, 96),
                                        outer.top + MulDiv(18, dpi, 96)});
        showIfChanged(item.handle, item.source && IsWindowVisible(item.window) && !app->selector &&
                                       !IsIconic(item.source));
    }
}
void refresh(Overlay &item) {
    updateFill(item);
    auto color = overlayColor(item);
    if (item.appliedColor != color) {
        item.appliedColor = color;
        InvalidateRect(item.window, nullptr, FALSE);
        if (item.handle)
            InvalidateRect(item.handle, nullptr, FALSE);
    }
}
LRESULT CALLBACK overlayProc(HWND, UINT, WPARAM, LPARAM);
LRESULT CALLBACK fillProc(HWND, UINT, WPARAM, LPARAM);
LRESULT CALLBACK handleProc(HWND, UINT, WPARAM, LPARAM);
LRESULT CALLBACK selectionProc(HWND, UINT, WPARAM, LPARAM);
void createOverlay(RECT area, HWND source = nullptr, bool element = false) {
    auto item = std::make_unique<Overlay>();
    item->id = app->nextId++;
    item->source = source;
    item->element = element;
    if (source && element) {
        auto r = windowBounds(source);
        item->relative = {area.left - r.left, area.top - r.top, area.right - r.left, area.bottom - r.top};
    }
    auto *raw = item.get();
    raw->window =
        CreateWindowExW(WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TOOLWINDOW, L"PNClipOverlay", L"PNClip",
                        WS_POPUP, area.left - edge, area.top - header, area.right - area.left + 2 * edge,
                        area.bottom - area.top + header + edge, nullptr, nullptr, app->instance, raw);
    if (!raw->window) {
        app->message(L"캡처 창을 만들지 못했습니다.", true);
        return;
    }
    SetLayeredWindowAttributes(raw->window, transparent, 255, LWA_COLORKEY);
    SetWindowDisplayAffinity(raw->window, WDA_EXCLUDEFROMCAPTURE);
    raw->fill = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"PNClipFill", L"",
                                WS_POPUP, area.left, area.top, area.right - area.left, area.bottom - area.top,
                                raw->window, nullptr, app->instance, raw);
    SetWindowDisplayAffinity(raw->fill, WDA_EXCLUDEFROMCAPTURE);
    if (source) {
        raw->handle = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"PNClipHandle", L"PNClip 창 메뉴",
                                      WS_POPUP, 0, 0, 14, 18, raw->window, nullptr, app->instance, raw);
        SetWindowDisplayAffinity(raw->handle, WDA_EXCLUDEFROMCAPTURE);
    }
    auto hwnd = raw->window;
    app->overlays.emplace(hwnd, std::move(item));
    app->selected = hwnd;
    refresh(*raw);
    ShowWindow(hwnd, SW_SHOW);
    ShowWindow(raw->fill, SW_SHOWNOACTIVATE);
    updateFill(*raw);
    SetForegroundWindow(hwnd);
}
void createDefault() {
    POINT p{};
    GetCursorPos(&p);
    MONITORINFO info{sizeof(info)};
    GetMonitorInfoW(MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST), &info);
    auto r = info.rcWork;
    int width = std::min(640L, r.right - r.left - 60), height = std::min(360L, r.bottom - r.top - 100);
    LONG x = r.left + (r.right - r.left - width) / 2, y = r.top + (r.bottom - r.top - height) / 2;
    createOverlay({x, y, x + width, y + height});
}
CaptureTarget targetFor(Overlay &item) {
    CaptureTarget target;
    target.sessionId = item.id;
    target.nativeScale = app->controller.settings().nativeScale;
    auto area = contentBounds(item.window);
    auto monitor = MonitorFromRect(&area, MONITOR_DEFAULTTONEAREST);
    auto scale = monitorScaleWin(monitor);
    target.pixelScale = target.nativeScale ? scale : 1;
    if (item.source) {
        target.source = CaptureSource::window;
        target.sourceWindow = (WindowId)(uintptr_t)item.source;
        auto r = windowBounds(item.source);
        scale = GetDpiForWindow(item.source) / 96.0;
        target.sourceWindowSize = {0, 0, (r.right - r.left) / scale, (r.bottom - r.top) / scale};
        if (item.element)
            target.cropPixels = {(double)item.relative.left, (double)item.relative.top,
                                 (double)(item.relative.right - item.relative.left),
                                 (double)(item.relative.bottom - item.relative.top)};
    } else {
        MONITORINFO info{sizeof(info)};
        GetMonitorInfoW(monitor, &info);
        if (area.left < info.rcMonitor.left || area.top < info.rcMonitor.top ||
            area.right > info.rcMonitor.right || area.bottom > info.rcMonitor.bottom) {
            app->message(L"캡처 영역을 하나의 모니터 안에 배치해 주세요.", true);
            return {};
        }
        target.source = CaptureSource::display;
        target.displayId = (uint64_t)(uintptr_t)monitor;
        target.captureArea = {(area.left - info.rcMonitor.left) / scale,
                              (area.top - info.rcMonitor.top) / scale, (area.right - area.left) / scale,
                              (area.bottom - area.top) / scale};
    }
    for (auto &[hwnd, other] : app->overlays) {
        target.excludedWindows.push_back((WindowId)(uintptr_t)hwnd);
        target.excludedWindows.push_back((WindowId)(uintptr_t)other->fill);
        if (other->handle)
            target.excludedWindows.push_back((WindowId)(uintptr_t)other->handle);
    }
    return target;
}
RecordingCallback recordingCallback() {
    return [](std::filesystem::path path, ServiceError error) {
        app->post([path = std::move(path), error = std::move(error)] {
            if (error.code) {
                app->message(wide(error.message), true);
                return;
            }
            if (!path.empty()) {
                app->last = path;
                if (!app->controller.copyFile(path))
                    app->notify(L"저장했습니다 · 클립보드 사용 중", path.filename().wstring());
            }
        });
    };
}
void pickFolder() {
    auto dialog = winrt::create_instance<IFileOpenDialog>(CLSID_FileOpenDialog);
    DWORD options{};
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
    dialog->SetTitle(L"PNClip 저장 폴더");
    if (SUCCEEDED(dialog->Show(app->selected))) {
        winrt::com_ptr<IShellItem> item;
        dialog->GetResult(item.put());
        PWSTR path{};
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
            auto settings = app->controller.settings();
            settings.destinationFolder = path;
            CoTaskMemFree(path);
            app->controller.updateSettings(settings);
        }
    }
}
void showPrefix() {
    if (app->prefixWindow) {
        SetForegroundWindow(app->prefixWindow);
        return;
    }
    app->prefixWindow = CreateWindowExW(WS_EX_TOOLWINDOW, L"PNClipPrefix", L"저장 파일명 접두사",
                                        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT,
                                        400, 145, app->hub, nullptr, app->instance, nullptr);
    app->prefixEdit =
        CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", wide(app->controller.settings().filenamePrefix).c_str(),
                        WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, 18, 18, 350, 26,
                        app->prefixWindow, (HMENU)1, app->instance, nullptr);
    SendMessageW(app->prefixEdit, EM_SETLIMITTEXT, 80, 0);
    CreateWindowW(L"BUTTON", L"저장", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, 278, 58, 90, 28,
                  app->prefixWindow, (HMENU)IDOK, app->instance, nullptr);
    ShowWindow(app->prefixWindow, SW_SHOW);
    SetFocus(app->prefixEdit);
}
void startSelection();
void showTransparency();
void showLicenses();
void shutdown() {
    if (app->closing)
        return;
    {
        std::lock_guard lock(app->queueMutex);
        app->closing = true;
    }
    // Keep the tray item alive until all capture/encoding workers have finished.
    if (app->selector)
        SendMessageW(app->selector, WM_KEYDOWN, VK_ESCAPE, 0);
    while (!app->overlays.empty())
        DestroyWindow(app->overlays.begin()->first);
    app->capture.reset();
    if (app->trayRegistered) {
        Shell_NotifyIconW(NIM_DELETE, &app->tray);
        app->trayRegistered = false;
    }
    DestroyWindow(app->hub);
}
void execute(int command) {
    if (command >= windowCommandBase) {
        const auto index = static_cast<size_t>(command - windowCommandBase);
        if (index < app->menuWindows.size()) {
            for (auto &[window, overlay] : app->overlays)
                if (overlay->id == app->menuWindows[index]) {
                    app->selected = window;
                    SetForegroundWindow(window);
                    break;
                }
        }
        return;
    }
    auto *item = app->current();
    auto settings = app->controller.settings();
    if (command >= PngGif && command <= Native && app->anyActive()) {
        app->message(L"녹화를 종료한 후 형식과 녹화 설정을 변경해 주세요.");
        return;
    }
    switch (command) {
    case New:
        createDefault();
        break;
    case Select:
        startSelection();
        break;
    case Still:
        if (item) {
            auto target = targetFor(*item);
            if (!target.valid())
                break;
            item->flashUntil = GetTickCount64() + 250;
            refresh(*item);
            app->controller.capture(target, [settings](PixelBuffer image, ServiceError error) mutable {
                std::filesystem::path path;
                if (!error.code && image.valid()) {
                    winrt::init_apartment(winrt::apartment_type::multi_threaded);
                    error = saveStillWin(image, settings, path);
                    winrt::uninit_apartment();
                }
                app->post(
                    [image = std::move(image), path = std::move(path), error = std::move(error), settings] {
                        if (error.code) {
                            app->message(wide(error.message), true);
                            return;
                        }
                        if (path.empty())
                            return;
                        app->last = path;
                        if (!app->clipboard->copyImage(image, settings.format, path))
                            app->notify(L"저장했습니다 · 클립보드 사용 중", path.filename().wstring());
                    });
            });
        }
        break;
    case Record:
    case Rolling:
        if (item) {
            if (command == Record && app->controller.isRecording(item->id))
                app->controller.stopRecording(item->id);
            else if (app->controller.isRolling(item->id))
                app->controller.stopRolling(item->id);
            else {
                auto target = targetFor(*item);
                if (!target.valid())
                    break;
                if (command == Record)
                    app->controller.toggleRecording(target, recordingCallback());
                else
                    app->controller.toggleRolling(target, recordingCallback());
            }
            refresh(*item);
        }
        break;
    case SaveRecent:
        if (item)
            app->controller.saveRolling(item->id, settings.maximumDuration);
        break;
    case Close:
        if (item)
            DestroyWindow(item->window);
        break;
    case CloseAll:
        while (!app->overlays.empty())
            DestroyWindow(app->overlays.begin()->first);
        break;
    case Detach:
        if (item && item->source && !app->active(item)) {
            item->source = nullptr;
            item->element = false;
            item->relative = {};
            refresh(*item);
            SetForegroundWindow(item->window);
        }
        break;
    case OpenLast:
        if (!app->last.empty() && !app->controller.open(app->last))
            app->message(L"파일을 열지 못했습니다.", true);
        break;
    case OpenFolder:
        if (!app->controller.open(settings.destinationFolder))
            app->message(L"저장 폴더를 열지 못했습니다.", true);
        break;
    case Folder:
        pickFolder();
        break;
    case Prefix:
        showPrefix();
        break;
    case PngGif:
        settings.format = CaptureFormat::pngGif;
        app->controller.updateSettings(settings);
        break;
    case WebP:
        settings.format = CaptureFormat::webP;
        app->controller.updateSettings(settings);
        break;
    case Five:
        settings.maximumDuration = 5s;
        app->controller.updateSettings(settings);
        break;
    case Ten:
        settings.maximumDuration = 10s;
        app->controller.updateSettings(settings);
        break;
    case Standard:
        settings.nativeScale = false;
        app->controller.updateSettings(settings);
        break;
    case Native:
        settings.nativeScale = true;
        app->controller.updateSettings(settings);
        break;
    case PassThrough:
        if (item) {
            item->pass = !item->pass;
            refresh(*item);
        }
        break;
    case Opacity20:
    case Opacity50:
    case Opacity80:
        if (item) {
            item->opacity = command == Opacity20 ? 204 : command == Opacity50 ? 128 : 51;
            refresh(*item);
        }
        break;
    case Startup:
        if (!app->controller.setStartupEnabled(!app->startup->enabled()))
            app->message(L"시작 프로그램 설정을 저장하지 못했습니다.", true);
        break;
    case Transparency:
        showTransparency();
        break;
    case Licenses:
        showLicenses();
        break;
    case Help:
        app->message(
            L"PNClip · Windows\n\n파란 테두리를 움직이거나 크기를 바꿔 영역을 지정하세요.\n트레이 클릭: 선택 "
            L"· 드래그: 자유 영역 · 클릭: 원본 창 연결\n선택 중 Shift: UI 요소 선택 · Esc / 우클릭: "
            L"취소\n\nCtrl+S: 스크린샷\nCtrl+R: 녹화 시작 / 종료\nCtrl+Alt+R: 최근 구간 상시 녹화\nCtrl+C: "
            L"최근 구간 저장\nCtrl+N / Ctrl+T: 새 영역 · Ctrl+W / Esc: 닫기\nCtrl+O: 최근 파일 · Ctrl+Alt+O: "
            L"저장 폴더\n\n다른 앱 사용 중 전역 단축키:\nCtrl+Shift+R: 선택한 영역 녹화 시작 / "
            L"종료\nCtrl+Shift+C: 선택한 영역의 최근 구간 저장\nCtrl+Shift+S: 영역 선택\n\n우클릭 메뉴에서 "
            L"형식, 길이, 해상도, 저장 위치를 바꿀 수 있습니다.\n녹화 버퍼는 영역당 최대 512 "
            L"MB입니다.\nWebP: libwebp 1.6.0 (배포 폴더 LICENSE 참고)");
        break;
    case Quit:
        shutdown();
        break;
    }
}
HMENU buildTrayMenu() {
    auto root = CreatePopupMenu();
    auto *overlay = app->current();
    auto settings = app->controller.settings();
    auto add = [](HMENU parent, UINT id, const wchar_t *name, bool checked = false, bool enabled = true) {
        AppendMenuW(parent, MF_STRING | (checked ? MF_CHECKED : 0) | (enabled ? 0 : MF_GRAYED), id, name);
    };
    auto separator = [](HMENU parent) { AppendMenuW(parent, MF_SEPARATOR, 0, nullptr); };
    auto submenu = [](HMENU parent, const wchar_t *name) {
        auto child = CreatePopupMenu();
        AppendMenuW(parent, MF_POPUP, (UINT_PTR)child, name);
        return child;
    };
    add(root, Select, L"영역 / 창 선택\tCtrl+Shift+S");
    separator(root);
    auto file = submenu(root, L"파일");
    add(file, New, L"새 창\tCtrl+N");
    add(file, Close, L"창 닫기\tCtrl+W", false, overlay);
    add(file, CloseAll, L"모든 창 닫기\tCtrl+Alt+W", false, !app->overlays.empty());
    separator(file);
    add(file, OpenLast, L"최근 캡처 열기\tCtrl+O", false, !app->last.empty());
    add(file, OpenFolder, L"저장 폴더 열기\tCtrl+Alt+O");
    separator(file);
    add(file, Folder, L"저장 위치 변경…");
    add(file, Prefix, L"저장 파일명…");
    auto format = submenu(file, L"파일 형식");
    add(format, PngGif, L"PNG / GIF", settings.format == CaptureFormat::pngGif, !app->anyActive());
    add(format, WebP, L"WebP", settings.format == CaptureFormat::webP, !app->anyActive());
    auto capture = submenu(root, L"캡처");
    add(capture, Still, L"캡처\tCtrl+S", false, overlay);
    add(capture, Record, L"화면 녹화 시작/중지\tCtrl+R", false, overlay);
    add(capture, Rolling, L"최근 구간 상시 녹화\tCtrl+Alt+R",
        overlay && app->controller.isRolling(overlay->id), overlay);
    add(capture, SaveRecent, L"최근 구간 저장\tCtrl+C", false,
        overlay && app->controller.isRolling(overlay->id));
    separator(capture);
    auto duration = submenu(capture, L"녹화 길이");
    add(duration, Five, L"5초", settings.maximumDuration == 5s, !app->anyActive());
    add(duration, Ten, L"10초", settings.maximumDuration == 10s, !app->anyActive());
    auto scale = submenu(capture, L"녹화 해상도");
    add(scale, Standard, L"일반", !settings.nativeScale, !app->anyActive());
    add(scale, Native, L"원본 픽셀 (Retina)", settings.nativeScale, !app->anyActive());
    separator(capture);
    add(capture, PassThrough, L"녹화 중 마우스 입력", overlay && overlay->pass, overlay && !app->anyActive());
    auto view = submenu(root, L"보기");
    add(view, Transparency, L"중앙 투명도…", false, overlay);
    auto windows = submenu(root, L"캡처 창 관리");
    app->menuWindows.clear();
    for (auto &[window, entry] : app->overlays) {
        wchar_t title[160]{};
        if (entry->source)
            GetWindowTextW(entry->source, title, 160);
        std::wstring label =
            L"#" + std::to_wstring(entry->id) + (entry->source ? L" · 연결: " : L" · 자유 영역");
        if (entry->source)
            label += *title ? title : L"제목 없는 창";
        // Escape native menu mnemonic markers in external window titles.
        std::wstring escaped;
        for (auto c : label) {
            escaped += c;
            if (c == L'&')
                escaped += c;
        }
        add(windows, windowCommandBase + static_cast<UINT>(app->menuWindows.size()), escaped.c_str(),
            window == app->selected);
        app->menuWindows.push_back(entry->id);
    }
    if (app->menuWindows.empty())
        add(windows, 0, L"열린 캡처 창 없음", false, false);
    separator(windows);
    add(windows, Detach, L"선택한 창 연결 해제", false, overlay && overlay->source && !app->active(overlay));
    add(windows, Close, L"선택한 캡처 창 닫기", false, overlay);
    if (overlay && app->active(overlay)) {
        std::wostringstream label;
        label << L"예상 녹화: 약 " << app->controller.estimatedRecordingSize(overlay->id) / (1024 * 1024)
              << L" MB";
        separator(root);
        add(root, 0, label.str().c_str(), false, false);
    }
    separator(root);
    add(root, Startup, L"로그인 시 실행", app->startup->enabled());
    add(root, Licenses, L"오픈 소스 라이선스…");
    add(root, Help, L"사용법 / 단축키");
    separator(root);
    add(root, Quit, L"PNClip 종료\tCtrl+Q");
    return root;
}
void menu(HWND owner, POINT point) {
    auto popup = buildTrayMenu();
    SetForegroundWindow(owner);
    int command = TrackPopupMenu(popup, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, owner, nullptr);
    DestroyMenu(popup);
    if (command)
        execute(command);
    if (IsWindow(owner))
        PostMessageW(owner, WM_NULL, 0, 0);
}
void paintOverlay(HWND window, Overlay &item) {
    PAINTSTRUCT paint;
    auto dc = BeginPaint(window, &paint);
    RECT area;
    GetClientRect(window, &area);
    // Compose the border and color-key hole offscreen. Never expose the temporary
    // solid rectangle to the layered-window compositor.
    auto buffer = CreateCompatibleDC(dc);
    auto bitmap = CreateCompatibleBitmap(dc, std::max(1L, area.right), std::max(1L, area.bottom));
    auto previous = SelectObject(buffer, bitmap);
    auto brush = CreateSolidBrush(overlayColor(item));
    FillRect(buffer, &area, brush);
    DeleteObject(brush);
    RECT inside{edge, header, area.right - edge, area.bottom - edge};
    brush = CreateSolidBrush(transparent);
    FillRect(buffer, &inside, brush);
    DeleteObject(brush);
    BitBlt(dc, 0, 0, area.right, area.bottom, buffer, 0, 0, SRCCOPY);
    SelectObject(buffer, previous);
    DeleteObject(bitmap);
    DeleteDC(buffer);
    EndPaint(window, &paint);
}
// Same logical geometry as CaptureViewMac::resizeEdgeAtPoint. Windows receives
// physical screen pixels, so normalize to DIPs before testing the Mac point sizes.
LRESULT resizeHitAtPoint(double x, double y, double width, double height) {
    if (x < 0 || y < 0 || x >= width || y >= height)
        return HTNOWHERE;
    const double corner = std::min(22.0, std::min(width, height) / 2.0);
    const double band = std::min(12.0, corner);
    if (x < corner && y < corner)
        return HTTOPLEFT;
    if (x >= width - corner && y < corner)
        return HTTOPRIGHT;
    if (x < corner && y >= height - corner)
        return HTBOTTOMLEFT;
    if (x >= width - corner && y >= height - corner)
        return HTBOTTOMRIGHT;
    if (y >= corner && y < height - corner) {
        if (x < band)
            return HTLEFT;
        if (x >= width - band)
            return HTRIGHT;
    }
    if (x >= corner && x < width - corner) {
        if (y < band)
            return HTTOP;
        if (y >= height - band)
            return HTBOTTOM;
    }
    return HTCLIENT;
}
LRESULT resizeHitInScreenRect(const RECT &rectangle, POINT screenPoint, UINT dpi) {
    const double scale = (dpi ? dpi : 96) / 96.0;
    return resizeHitAtPoint((screenPoint.x - rectangle.left) / scale, (screenPoint.y - rectangle.top) / scale,
                            (rectangle.right - rectangle.left) / scale,
                            (rectangle.bottom - rectangle.top) / scale);
}
LRESULT overlayResizeHit(const Overlay &item, POINT screenPoint) {
    if (item.source || app->active(&item))
        return HTCLIENT;
    RECT rectangle{};
    GetWindowRect(item.window, &rectangle);
    return resizeHitInScreenRect(rectangle, screenPoint, GetDpiForWindow(item.window));
}
HCURSOR resizeCursor(LRESULT hit) {
    switch (hit) {
    case HTTOPLEFT:
    case HTBOTTOMRIGHT:
        return LoadCursorW(nullptr, IDC_SIZENWSE);
    case HTTOPRIGHT:
    case HTBOTTOMLEFT:
        return LoadCursorW(nullptr, IDC_SIZENESW);
    case HTLEFT:
    case HTRIGHT:
        return LoadCursorW(nullptr, IDC_SIZEWE);
    case HTTOP:
    case HTBOTTOM:
        return LoadCursorW(nullptr, IDC_SIZENS);
    default:
        return LoadCursorW(nullptr, IDC_ARROW);
    }
}
LRESULT CALLBACK handleProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    auto *item = (Overlay *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        item = (Overlay *)((CREATESTRUCTW *)l)->lpCreateParams;
        SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)item);
    }
    if (!item)
        return DefWindowProcW(window, message, w, l);
    switch (message) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        auto dc = BeginPaint(window, &ps);
        RECT rectangle{};
        GetClientRect(window, &rectangle);
        auto color = app->controller.isRolling(item->id)     ? RGB(240, 31, 31)
                     : app->controller.isRecording(item->id) ? RGB(255, 122, 20)
                                                             : RGB(41, 163, 255);
        auto brush = CreateSolidBrush(color);
        FillRect(dc, &rectangle, brush);
        DeleteObject(brush);
        EndPaint(window, &ps);
        return 0;
    }
    case WM_SETCURSOR:
        SetCursor(LoadCursorW(nullptr, IDC_HAND));
        return TRUE;
    case WM_LBUTTONUP:
    case WM_RBUTTONUP: {
        const auto owner = item->window;
        app->selected = owner;
        SetForegroundWindow(owner);
        auto popup = CreatePopupMenu();
        AppendMenuW(popup, MF_STRING, Still, L"캡처");
        AppendMenuW(popup, MF_STRING, Record, L"녹화 시작 / 중지");
        AppendMenuW(popup, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(popup, MF_STRING | (app->active(item) ? MF_GRAYED : 0), Detach, L"연결 해제");
        AppendMenuW(popup, MF_STRING, Close, L"캡처 창 닫기");
        RECT rectangle{};
        GetWindowRect(window, &rectangle);
        auto command = TrackPopupMenu(popup, TPM_RETURNCMD | TPM_RIGHTBUTTON, rectangle.left,
                                      rectangle.bottom, 0, owner, nullptr);
        DestroyMenu(popup);
        if (command)
            execute(command);
        return 0;
    }
    }
    return DefWindowProcW(window, message, w, l);
}
LRESULT CALLBACK fillProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    auto *item = (Overlay *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        item = (Overlay *)((CREATESTRUCTW *)l)->lpCreateParams;
        SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)item);
    }
    if (!item)
        return DefWindowProcW(window, message, w, l);
    switch (message) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        auto dc = BeginPaint(window, &ps);
        RECT r;
        GetClientRect(window, &r);
        FillRect(dc, &r, (HBRUSH)GetStockObject(BLACK_BRUSH));
        EndPaint(window, &ps);
        return 0;
    }
    case WM_SETCURSOR: {
        POINT point{};
        GetCursorPos(&point);
        SetCursor(resizeCursor(overlayResizeHit(*item, point)));
        return TRUE;
    }
    case WM_LBUTTONDOWN: {
        app->selected = item->window;
        SetForegroundWindow(item->window);
        if (!item->source && !app->active(item)) {
            POINT point{GET_X_LPARAM(l), GET_Y_LPARAM(l)};
            ClientToScreen(window, &point);
            const auto hit = overlayResizeHit(*item, point);
            ReleaseCapture();
            // The translucent center is a separate owned window. Route its resize
            // bands to the outline, never resize the center window itself.
            SendMessageW(item->window, WM_NCLBUTTONDOWN, hit == HTCLIENT ? HTCAPTION : hit,
                         MAKELPARAM(point.x, point.y));
        }
        return 0;
    }
    case WM_RBUTTONUP: {
        app->selected = item->window;
        POINT point;
        GetCursorPos(&point);
        menu(item->window, point);
        return 0;
    }
    }
    return DefWindowProcW(window, message, w, l);
}
LRESULT CALLBACK overlayProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    auto *item = (Overlay *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        item = (Overlay *)((CREATESTRUCTW *)l)->lpCreateParams;
        SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)item);
    }
    if (!item)
        return DefWindowProcW(window, message, w, l);
    switch (message) {
    case WM_PAINT:
        paintOverlay(window, *item);
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_ACTIVATE:
        if (LOWORD(w) != WA_INACTIVE)
            app->selected = window;
        return 0;
    case WM_WINDOWPOSCHANGED:
        if (item->fill)
            updateFill(*item);
        break;
    case WM_SIZE:
        // Repaint the old right/bottom border too, not just newly exposed pixels.
        RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_NOERASE);
        return 0;
    case WM_GETMINMAXINFO: {
        const auto dpi = GetDpiForWindow(window);
        ((MINMAXINFO *)l)->ptMinTrackSize = {MulDiv(160, dpi, 96), MulDiv(100, dpi, 96)};
        return 0;
    }
    case WM_NCHITTEST: {
        POINT p{GET_X_LPARAM(l), GET_Y_LPARAM(l)};
        return overlayResizeHit(*item, p);
    }
    case WM_LBUTTONUP:
        app->selected = window;
        return 0;
    case WM_CONTEXTMENU: {
        app->selected = window;
        POINT p;
        GetCursorPos(&p);
        menu(window, p);
        return 0;
    }
    case WM_DPICHANGED: {
        auto *r = (RECT *)l;
        if (!item->source && !app->active(item))
            SetWindowPos(window, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top,
                         SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_DESTROY: {
        auto id = item->id;
        app->controller.stopRecording(id);
        app->controller.stopRolling(id);
        if (item->fill)
            DestroyWindow(item->fill);
        if (item->handle)
            DestroyWindow(item->handle);
        app->overlays.erase(window);
        if (app->selected == window)
            app->selected = app->overlays.empty() ? nullptr : app->overlays.begin()->first;
        return 0;
    }
    }
    return DefWindowProcW(window, message, w, l);
}
struct WindowHit {
    POINT point;
    HWND found{};
};
BOOL CALLBACK hitWindow(HWND window, LPARAM param) {
    auto &hit = *(WindowHit *)param;
    DWORD process{};
    GetWindowThreadProcessId(window, &process);
    if (process == GetCurrentProcessId() || !IsWindowVisible(window) || IsIconic(window))
        return TRUE;
    DWORD cloaked = 0;
    DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
    if (cloaked)
        return TRUE;
    auto r = windowBounds(window);
    if (PtInRect(&r, hit.point)) {
        hit.found = window;
        return FALSE;
    }
    return TRUE;
}
RECT accessibleElementAt(HWND source, POINT point, RECT fallback) {
    winrt::com_ptr<IAccessible> node;
    if (FAILED(AccessibleObjectFromWindow(source, static_cast<DWORD>(OBJID_CLIENT), IID_IAccessible,
                                          node.put_void())))
        return fallback;
    RECT best = fallback;
    // Query the source provider directly. Desktop hit testing would return our
    // selection overlay, and walking HWNDs cannot reach browser page content.
    const auto deadline = GetTickCount64() + 150;
    for (int depth = 0; node && depth < 64 && GetTickCount64() < deadline; ++depth) {
        VARIANT hit{};
        if (FAILED(node->accHitTest(point.x, point.y, &hit))) {
            VariantClear(&hit);
            break;
        }
        winrt::com_ptr<IAccessible> next;
        VARIANT child{};
        child.vt = VT_I4;
        child.lVal = CHILDID_SELF;
        if (hit.vt == VT_DISPATCH && hit.pdispVal)
            hit.pdispVal->QueryInterface(IID_IAccessible, next.put_void());
        else if (hit.vt == VT_I4)
            child.lVal = hit.lVal;
        else {
            VariantClear(&hit);
            break;
        }
        long x{}, y{}, width{}, height{};
        auto location = next ? next.get() : node.get();
        if (SUCCEEDED(location->accLocation(&x, &y, &width, &height, child)) && width > 0 && height > 0) {
            RECT r{x, y, x + width, y + height}, clipped{};
            if (PtInRect(&r, point) && IntersectRect(&clipped, &r, &fallback) &&
                (long long)(clipped.right - clipped.left) * (clipped.bottom - clipped.top) <=
                    (long long)(best.right - best.left) * (best.bottom - best.top))
                best = clipped;
        }
        if (!next && child.lVal != CHILDID_SELF) {
            winrt::com_ptr<IDispatch> dispatch;
            if (SUCCEEDED(node->get_accChild(child, dispatch.put())) && dispatch)
                dispatch->QueryInterface(IID_IAccessible, next.put_void());
        }
        VariantClear(&hit);
        if (!next || next.as<IUnknown>() == node.as<IUnknown>())
            break;
        node = std::move(next);
    }
    return best;
}
RECT elementAt(HWND source, POINT point, RECT fallback) {
    RECT best = fallback;
    // Start at the native child under the pointer, not at the top-level window.
    // This also works when an application does not expose an automation tree.
    HWND target = source;
    for (int depth = 0; depth < 64; ++depth) {
        POINT local = point;
        ScreenToClient(target, &local);
        HWND child = ChildWindowFromPointEx(target, local, CWP_SKIPINVISIBLE | CWP_SKIPTRANSPARENT);
        if (!child || child == target)
            break;
        target = child;
        RECT r{}, clipped{};
        if (GetWindowRect(target, &r) && PtInRect(&r, point) && IntersectRect(&clipped, &r, &fallback))
            if ((long long)(clipped.right - clipped.left) * (clipped.bottom - clipped.top) <
                (long long)(best.right - best.left) * (best.bottom - best.top))
                best = clipped;
    }
    best = accessibleElementAt(target, point, best);
    if (!app->automation)
        return best;
    winrt::com_ptr<IUIAutomationElement> node;
    if (FAILED(app->automation->ElementFromHandle(target, node.put())))
        return best;
    winrt::com_ptr<IUIAutomationTreeWalker> walker;
    app->automation->get_RawViewWalker(walker.put());
    if (!walker)
        return best;
    const auto deadline = GetTickCount64() + 150;
    int remaining = 2048;
    auto area = [](RECT r) { return (long long)(r.right - r.left) * (r.bottom - r.top); };
    // Raw view includes text and layout elements omitted by Control view.
    // Search every overlapping branch; an empty container must not hide children.
    auto visit = [&](auto &&self, IUIAutomationElement *parent, int depth) -> void {
        if (depth >= 64 || remaining <= 0 || GetTickCount64() >= deadline)
            return;
        winrt::com_ptr<IUIAutomationElement> child;
        walker->GetFirstChildElement(parent, child.put());
        while (child && remaining-- > 0 && GetTickCount64() < deadline) {
            RECT r{};
            const bool hasBounds =
                SUCCEEDED(child->get_CurrentBoundingRectangle(&r)) && r.right > r.left && r.bottom > r.top;
            if (!hasBounds || PtInRect(&r, point)) {
                RECT clipped{};
                if (hasBounds && IntersectRect(&clipped, &r, &fallback) && area(clipped) < area(best))
                    best = clipped;
                self(self, child.get(), depth + 1);
            }
            winrt::com_ptr<IUIAutomationElement> next;
            walker->GetNextSiblingElement(child.get(), next.put());
            child = std::move(next);
        }
    };
    visit(visit, node.get(), 0);
    return best;
}
void updateSelection(POINT point) {
    if (app->dragging)
        app->preview = {std::min(point.x, app->dragStart.x), std::min(point.y, app->dragStart.y),
                        std::max(point.x, app->dragStart.x), std::max(point.y, app->dragStart.y)};
    else {
        WindowHit hit{point};
        EnumWindows(hitWindow, (LPARAM)&hit);
        app->previewSource = hit.found;
        app->previewElement = false;
        app->preview = hit.found ? windowBounds(hit.found) : RECT{};
        if (hit.found && (GetAsyncKeyState(VK_SHIFT) & 0x8000)) {
            auto r = elementAt(hit.found, point, app->preview);
            app->previewElement = !EqualRect(&r, &app->preview);
            app->preview = r;
        }
    }
    InvalidateRect(app->selector, nullptr, FALSE);
}
void endSelection() {
    if (app->selector) {
        auto window = app->selector;
        app->selector = nullptr;
        ReleaseCapture();
        DestroyWindow(window);
    }
    for (auto &[window, item] : app->overlays) {
        ShowWindow(window, SW_SHOWNOACTIVATE);
        ShowWindow(item->fill, SW_SHOWNOACTIVATE);
    }
}
void startSelection() {
    if (app->selector)
        return;
    for (auto &[window, item] : app->overlays) {
        ShowWindow(item->fill, SW_HIDE);
        ShowWindow(window, SW_HIDE);
    }
    app->dragging = false;
    app->selector =
        CreateWindowExW(WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TOOLWINDOW, L"PNClipSelection",
                        L"PNClip 영역 선택", WS_POPUP, GetSystemMetrics(SM_XVIRTUALSCREEN),
                        GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN),
                        GetSystemMetrics(SM_CYVIRTUALSCREEN), nullptr, nullptr, app->instance, nullptr);
    // Per-pixel alpha keeps the entire selection surface hit-testable. A color-key
    // hole also lets mouse clicks through, even though the window covers the screen.
    SetWindowDisplayAffinity(app->selector, WDA_EXCLUDEFROMCAPTURE);
    ShowWindow(app->selector, SW_SHOW);
    SetForegroundWindow(app->selector);
    POINT p;
    GetCursorPos(&p);
    updateSelection(p);
    UpdateWindow(app->selector);
    SetTimer(app->selector, 1, 100, nullptr);
}
LRESULT CALLBACK selectionProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    switch (message) {
    case WM_ERASEBKGND:
        return 1;
    case WM_SETCURSOR:
        SetCursor(LoadCursorW(nullptr, IDC_CROSS));
        return TRUE;
    case WM_TIMER:
        if (!app->dragging) {
            POINT p;
            GetCursorPos(&p);
            updateSelection(p);
        }
        return 0;
    case WM_MOUSEMOVE:
        if (app->dragging) {
            POINT p;
            GetCursorPos(&p);
            updateSelection(p);
        }
        return 0;
    case WM_LBUTTONDOWN:
        app->dragging = true;
        GetCursorPos(&app->dragStart);
        SetCapture(window);
        return 0;
    case WM_LBUTTONUP: {
        if (!app->dragging)
            return 0;
        POINT p;
        GetCursorPos(&p);
        auto start = app->dragStart;
        bool dragged = std::abs(p.x - start.x) > 5 || std::abs(p.y - start.y) > 5;
        RECT r;
        HWND source = nullptr;
        if (dragged) {
            updateSelection(p);
            r = app->preview;
        } else {
            app->dragging = false;
            updateSelection(p);
            r = app->preview;
            // Element picking supplies geometry only; only a whole-window pick attaches.
            source = app->previewElement ? nullptr : app->previewSource;
        }
        endSelection();
        if (r.right > r.left + 10 && r.bottom > r.top + 10)
            createOverlay(r, source);
        return 0;
    }
    case WM_RBUTTONDOWN:
        endSelection();
        return 0;
    case WM_KEYDOWN:
        if (w != VK_SHIFT)
            endSelection();
        return 0;
    case WM_CAPTURECHANGED:
        if (app->selector == window && app->dragging)
            endSelection();
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(window, &ps);
        RECT r;
        GetClientRect(window, &r);
        const int width = r.right, height = r.bottom;
        auto screen = GetDC(nullptr);
        auto dc = CreateCompatibleDC(screen);
        BITMAPINFO info{};
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        void *raw{};
        auto bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &raw, nullptr, 0);
        if (!bitmap || !dc) {
            if (bitmap)
                DeleteObject(bitmap);
            if (dc)
                DeleteDC(dc);
            ReleaseDC(nullptr, screen);
            EndPaint(window, &ps);
            return 0;
        }
        auto previous = SelectObject(dc, bitmap);
        auto *pixels = static_cast<uint32_t *>(raw);
        // Alpha=1 is visually near-transparent but receives input. Alpha=0 does not.
        std::fill_n(pixels, (size_t)width * height, 0x01000000u);
        r = app->preview;
        POINT origin{};
        ClientToScreen(window, &origin);
        OffsetRect(&r, -origin.x, -origin.y);
        auto pen = CreatePen(PS_SOLID, 4, RGB(255, 145, 32));
        auto oldPen = SelectObject(dc, pen);
        auto oldBrush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
        Rectangle(dc, r.left, r.top, r.right, r.bottom);
        SelectObject(dc, oldPen);
        SelectObject(dc, oldBrush);
        DeleteObject(pen);
        RECT hint{20, 20, 760, 58};
        auto brush = CreateSolidBrush(RGB(25, 30, 40));
        FillRect(dc, &hint, brush);
        DeleteObject(brush);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(255, 255, 255));
        SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
        DrawTextW(dc, L"드래그: 영역  ·  클릭: 창 연결  ·  Shift: UI 요소  ·  Esc / 우클릭: 취소", -1, &hint,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        // GDI drawing clears alpha; keep the drawn outline and hint fully opaque.
        GdiFlush();
        for (size_t i = 0; i < (size_t)width * height; ++i)
            pixels[i] = (pixels[i] & 0x00ffffff) ? pixels[i] | 0xff000000u : 0x01000000u;
        RECT bounds{};
        GetWindowRect(window, &bounds);
        POINT destination{bounds.left, bounds.top}, source{};
        SIZE size{width, height};
        BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
        UpdateLayeredWindow(window, screen, &destination, &size, dc, &source, 0, &blend, ULW_ALPHA);
        SelectObject(dc, previous);
        DeleteObject(bitmap);
        DeleteDC(dc);
        ReleaseDC(nullptr, screen);
        EndPaint(window, &ps);
        return 0;
    }
    }
    return DefWindowProcW(window, message, w, l);
}
void tick() {
    std::vector<HWND> gone;
    for (auto &[window, item] : app->overlays) {
        if (item->source) {
            if (!IsWindow(item->source)) {
                gone.push_back(window);
                continue;
            }
            bool visible = !IsIconic(item->source) && !app->selector;
            showIfChanged(window, visible);
            showIfChanged(item->fill, visible);
            if (visible) {
                auto r = windowBounds(item->source);
                if (item->element) {
                    r.right = r.left + item->relative.right;
                    r.bottom = r.top + item->relative.bottom;
                    r.left += item->relative.left;
                    r.top += item->relative.top;
                }
                auto current = contentBounds(window);
                if (app->active(item.get())) {
                    r.right = r.left + current.right - current.left;
                    r.bottom = r.top + current.bottom - current.top;
                }
                if (!EqualRect(&r, &current))
                    SetWindowPos(window, nullptr, r.left - edge, r.top - header, r.right - r.left + edge * 2,
                                 r.bottom - r.top + header + edge, SWP_NOZORDER | SWP_NOACTIVATE);
            }
        }
        refresh(*item);
    }
    for (auto window : gone)
        DestroyWindow(window);
}
HICON createTraySymbol() {
    DWORD light = 0, bytes = sizeof(light);
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &bytes);
    const unsigned shade = light ? 32 : 245;
    const int size = std::max(16, GetSystemMetrics(SM_CXSMICON));
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = size;
    info.bmiHeader.biHeight = -size;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    void *pixels{};
    HBITMAP color = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!color)
        return nullptr;
    // Four rounded viewfinder corners, matching the Mac menu-bar symbol.
    // Premultiplied alpha leaves both the outside and the centre transparent.
    for (int y = 0; y < size; ++y) {
        for (int x = 0; x < size; ++x) {
            int coverage = 0;
            for (int sy = 0; sy < 4; ++sy) {
                for (int sx = 0; sx < 4; ++sx) {
                    double px = (x + (sx + 0.5) / 4) * 16 / size;
                    double py = (y + (sy + 0.5) / 4) * 16 / size;
                    px = std::min(px, 16 - px);
                    py = std::min(py, 16 - py);
                    const double horizontal = std::hypot(px - std::clamp(px, 3.0, 6.0), py - 3);
                    const double vertical = std::hypot(px - 3, py - std::clamp(py, 3.0, 6.0));
                    coverage += std::min(horizontal, vertical) <= 0.9;
                }
            }
            unsigned alpha = coverage * 255 / 16, value = shade * alpha / 255;
            ((DWORD *)pixels)[y * size + x] = (alpha << 24) | (value << 16) | (value << 8) | value;
        }
    }
    std::vector<BYTE> maskBits(((size + 15) / 16) * 2 * size, 0);
    HBITMAP mask = CreateBitmap(size, size, 1, 1, maskBits.data());
    ICONINFO icon{TRUE, 0, 0, mask, color};
    HICON result = mask ? CreateIconIndirect(&icon) : nullptr;
    if (mask)
        DeleteObject(mask);
    DeleteObject(color);
    return result;
}
LRESULT CALLBACK hubProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (!app)
        return DefWindowProcW(window, message, w, l);
    if (message == app->taskbarCreated) {
        // Explorer has discarded the registered item: do not leave an invisible app running.
        if (app->trayRegistered)
            shutdown();
        return 0;
    }
    switch (message) {
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
        if (app->trayRegistered) {
            if (auto icon = createTraySymbol()) {
                auto previous = app->traySymbol;
                app->traySymbol = icon;
                app->tray.hIcon = icon;
                app->tray.uFlags = NIF_ICON;
                Shell_NotifyIconW(NIM_MODIFY, &app->tray);
                if (previous)
                    DestroyIcon(previous);
            }
        }
        return 0;
    case dispatchMessage:
        app->drain();
        return 0;
    case WM_TIMER:
        tick();
        if (app->trayRegistered && GetTickCount64() - app->lastTrayUpdate >= 1000) {
            app->lastTrayUpdate = GetTickCount64();
            app->tray.uFlags = NIF_TIP;
            std::wstring tip = L"PNClip · 왼쪽 클릭: 영역 선택 / 오른쪽 클릭: 메뉴";
            if (auto *item = app->current(); app->active(item))
                tip += L" · 약 " +
                       std::to_wstring(app->controller.estimatedRecordingSize(item->id) / (1024 * 1024)) +
                       L" MB";
            wcsncpy_s(app->tray.szTip, tip.c_str(), _TRUNCATE);
            if (!Shell_NotifyIconW(NIM_MODIFY, &app->tray))
                shutdown();
        }
        return 0;
    case WM_CLOSE:
        shutdown();
        return 0;
    case WM_HOTKEY:
        execute(w == 1 ? Record : w == 2 ? SaveRecent : Select);
        return 0;
    case trayMessage:
        if (l == WM_LBUTTONUP)
            startSelection();
        else if (l == WM_RBUTTONUP) {
            POINT p;
            GetCursorPos(&p);
            menu(window, p);
        }
        return 0;
    case WM_DESTROY: {
        std::lock_guard lock(app->queueMutex);
        app->closing = true;
    }
        endSelection();
        while (!app->overlays.empty())
            DestroyWindow(app->overlays.begin()->first);
        for (int id = 1; id <= 3; ++id)
            UnregisterHotKey(window, id);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}
LRESULT CALLBACK prefixProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_COMMAND && LOWORD(w) == IDOK) {
        wchar_t prefix[81]{};
        GetWindowTextW(app->prefixEdit, prefix, 81);
        if (!*prefix || std::wstring(prefix).find_first_of(L"<>:\"/\\|?*") != std::wstring::npos) {
            app->message(L"파일명에 사용할 수 있는 접두사를 입력해 주세요.", true);
            return 0;
        }
        app->controller.updateFilenamePrefix(utf8(prefix));
        DestroyWindow(window);
        return 0;
    }
    if (message == WM_DESTROY) {
        app->prefixWindow = nullptr;
        app->prefixEdit = nullptr;
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}
LRESULT CALLBACK opacityProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_HSCROLL) {
        auto found = app->overlays.find(app->opacityTarget);
        if (found != app->overlays.end()) {
            int percent = (int)SendMessageW(app->opacitySlider, TBM_GETPOS, 0, 0);
            found->second->opacity = (BYTE)std::lround(255 * (100 - percent) / 100.0);
            refresh(*found->second);
            auto title = L"중앙 투명도 · " + std::to_wstring(percent) + L"%";
            SetWindowTextW(window, title.c_str());
        }
        return 0;
    }
    if (message == WM_DESTROY) {
        app->opacityWindow = nullptr;
        app->opacitySlider = nullptr;
        app->opacityTarget = nullptr;
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}
void showTransparency() {
    auto *item = app->current();
    if (!item)
        return;
    app->opacityTarget = item->window;
    if (!app->opacityWindow) {
        app->opacityWindow = CreateWindowExW(
            WS_EX_TOOLWINDOW, L"PNClipOpacity", L"중앙 투명도", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
            CW_USEDEFAULT, CW_USEDEFAULT, 320, 110, app->hub, nullptr, app->instance, nullptr);
        app->opacitySlider =
            CreateWindowExW(0, TRACKBAR_CLASSW, L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | TBS_AUTOTICKS, 12,
                            12, 280, 40, app->opacityWindow, nullptr, app->instance, nullptr);
        SendMessageW(app->opacitySlider, TBM_SETRANGE, TRUE, MAKELPARAM(0, 100));
        SendMessageW(app->opacitySlider, TBM_SETTICFREQ, 10, 0);
    }
    int percent = (int)std::lround(100 - item->opacity * 100.0 / 255);
    SendMessageW(app->opacitySlider, TBM_SETPOS, TRUE, percent);
    auto title = L"중앙 투명도 · " + std::to_wstring(percent) + L"%";
    SetWindowTextW(app->opacityWindow, title.c_str());
    ShowWindow(app->opacityWindow, SW_SHOW);
    SetForegroundWindow(app->opacityWindow);
}
std::wstring licenseResource(int id) {
    auto resource = FindResourceW(app->instance, MAKEINTRESOURCEW(id), RT_RCDATA);
    if (!resource)
        return L"라이선스를 불러오지 못했습니다.";
    auto data = LoadResource(app->instance, resource);
    auto *text = (const char *)LockResource(data);
    std::wstring out = wide(std::string(text, SizeofResource(app->instance, resource)));
    std::wstring lines;
    for (auto c : out) {
        if (c == L'\n')
            lines += L'\r';
        lines += c;
    }
    return lines;
}
LRESULT CALLBACK licenseProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_SIZE) {
        auto edit = GetDlgItem(window, 1);
        if (edit)
            MoveWindow(edit, 12, 12, LOWORD(l) - 24, HIWORD(l) - 24, TRUE);
        return 0;
    }
    if (message == WM_DESTROY) {
        app->licenseWindow = nullptr;
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}
void showLicenses() {
    if (!app->licenseWindow) {
        app->licenseWindow = CreateWindowExW(WS_EX_TOOLWINDOW, L"PNClipLicense", L"오픈 소스 라이선스",
                                             WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 680, 500,
                                             app->hub, nullptr, app->instance, nullptr);
        auto text = L"libwebp 1.6.0\r\n\r\n" + licenseResource(2) + L"\r\n\r\n" + licenseResource(3);
        auto edit =
            CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", text.c_str(),
                            WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                            12, 12, 640, 430, app->licenseWindow, (HMENU)1, app->instance, nullptr);
        SendMessageW(edit, WM_SETFONT, (WPARAM)GetStockObject(DEFAULT_GUI_FONT), TRUE);
    }
    ShowWindow(app->licenseWindow, SW_SHOW);
    SetForegroundWindow(app->licenseWindow);
}
bool shortcut(MSG &message) {
    if ((message.message != WM_KEYDOWN && message.message != WM_SYSKEYDOWN) || app->selector ||
        app->prefixWindow || !app->overlays.contains(message.hwnd))
        return false;
    bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0, alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
    int command = 0;
    if (message.wParam == VK_ESCAPE)
        command = Close;
    if (ctrl)
        switch (message.wParam) {
        case 'S':
            command = Still;
            break;
        case 'R':
            command = alt ? Rolling : Record;
            break;
        case 'C':
            command = SaveRecent;
            break;
        case 'N':
        case 'T':
            command = New;
            break;
        case 'W':
            command = alt ? CloseAll : Close;
            break;
        case 'O':
            command = alt ? OpenFolder : OpenLast;
            break;
        case 'Q':
            command = Quit;
            break;
        }
    if (command) {
        execute(command);
        return true;
    }
    return false;
}
} // namespace
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR commandLine, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    winrt::init_apartment(winrt::apartment_type::single_threaded);
    int exitCode = 0;
    try {
        App state;
        app = &state;
        state.instance = instance;
        auto registerClass = [&](const wchar_t *name, WNDPROC procedure) {
            WNDCLASSEXW cls{sizeof(cls)};
            cls.lpfnWndProc = procedure;
            cls.hInstance = instance;
            cls.lpszClassName = name;
            cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
            cls.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
            return RegisterClassExW(&cls);
        };
        registerClass(L"PNClipHub", hubProc);
        registerClass(L"PNClipOverlay", overlayProc);
        registerClass(L"PNClipFill", fillProc);
        registerClass(L"PNClipHandle", handleProc);
        registerClass(L"PNClipSelection", selectionProc);
        registerClass(L"PNClipPrefix", prefixProc);
        registerClass(L"PNClipOpacity", opacityProc);
        registerClass(L"PNClipLicense", licenseProc);
        INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_BAR_CLASSES};
        InitCommonControlsEx(&controls);
        state.hub = CreateWindowExW(WS_EX_TOOLWINDOW, L"PNClipHub", L"PNClip", WS_POPUP, 0, 0, 0, 0, nullptr,
                                    nullptr, instance, nullptr);
        winrt::check_bool(state.hub != nullptr);
        CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IUIAutomation),
                         state.automation.put_void());
        if (auto automation2 = state.automation.try_as<IUIAutomation2>()) {
            automation2->put_ConnectionTimeout(200);
            automation2->put_TransactionTimeout(200);
        }
        state.tray.cbSize = sizeof(state.tray);
        state.tray.hWnd = state.hub;
        state.tray.uID = 1;
        state.tray.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        state.tray.uCallbackMessage = trayMessage;
        state.traySymbol = createTraySymbol();
        winrt::check_bool(state.traySymbol != nullptr);
        state.tray.hIcon = state.traySymbol;
        wcscpy_s(state.tray.szTip, L"PNClip · 클릭: 영역 선택 / 우클릭: 메뉴");
        state.trayRegistered = Shell_NotifyIconW(NIM_ADD, &state.tray) != FALSE;
        if (!state.trayRegistered) {
            state.message(L"트레이 아이콘을 등록하지 못해 PNClip을 종료합니다.", true);
            shutdown();
            app = nullptr;
            return 1;
        }
        bool hotkeys = RegisterHotKey(state.hub, 1, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'R') != FALSE;
        hotkeys =
            (RegisterHotKey(state.hub, 2, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'C') != FALSE) && hotkeys;
        hotkeys =
            (RegisterHotKey(state.hub, 3, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'S') != FALSE) && hotkeys;
        if (!hotkeys)
            state.notify(L"전역 단축키 충돌",
                         L"일부 단축키를 다른 앱이 사용 중입니다. 캡처 창이나 트레이 메뉴를 이용하세요.");
        SetTimer(state.hub, 1, 100, nullptr);
        if (std::wstring(commandLine).find(L"--tray") == std::wstring::npos)
            createDefault();
        MSG message;
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            if (state.prefixWindow && IsDialogMessageW(state.prefixWindow, &message))
                continue;
            if (shortcut(message))
                continue;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        state.capture.reset();
        app = nullptr;
    } catch (const winrt::hresult_error &error) {
        MessageBoxW(nullptr, error.message().c_str(), L"PNClip", MB_ICONERROR);
        exitCode = 1;
    } catch (const std::exception &error) {
        MessageBoxW(nullptr, wide(error.what()).c_str(), L"PNClip", MB_ICONERROR);
        exitCode = 1;
    }
    winrt::uninit_apartment();
    return exitCode;
}
