// Exercise the actual native UI implementation in a separate test process.
#include "../PNClip/mainWin.cpp"
#include <cassert>
#include <iostream>
#include <thread>
void pumpSelectionMessages() {
    auto until = std::chrono::steady_clock::now() + 80ms;
    while (std::chrono::steady_clock::now() < until) {
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        std::this_thread::sleep_for(2ms);
    }
}
void checkNativeSelectionDrag() {
    POINT previous{};
    GetCursorPos(&previous);
    RECT work{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    POINT start{work.left + 80, work.top + 100}, end{start.x + 240, start.y + 140};
    auto count = app->overlays.size();
    SendMessageW(app->hub, trayMessage, 0, WM_LBUTTONUP);
    pumpSelectionMessages();
    assert(app->selector && GetCapture() != app->selector);
    SetCursorPos(start.x, start.y);
    pumpSelectionMessages();
    assert(WindowFromPoint(start) == app->selector); // Actual hit testing, not a sent window message.
    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    assert(SendInput(1, &input, sizeof(input)) == 1);
    pumpSelectionMessages();
    assert(app->dragging && GetCapture() == app->selector);
    SetCursorPos(end.x, end.y);
    pumpSelectionMessages();
    input.mi.dwFlags = MOUSEEVENTF_LEFTUP;
    assert(SendInput(1, &input, sizeof(input)) == 1);
    pumpSelectionMessages();
    assert(!app->selector && app->overlays.size() == count + 1 && !app->current()->source);
    auto area = contentBounds(app->current()->window);
    assert(area.left == start.x && area.top == start.y && area.right == end.x && area.bottom == end.y);
    execute(Close);
    SetCursorPos(previous.x, previous.y);
}
LRESULT CALLBACK countRenderEvents(HWND window, UINT message, WPARAM w, LPARAM l, UINT_PTR, DWORD_PTR data) {
    if (message == WM_PAINT || message == WM_WINDOWPOSCHANGED || message == WM_STYLECHANGED ||
        message == WM_SHOWWINDOW)
        ++*(int *)data;
    return DefSubclassProc(window, message, w, l);
}
void checkStableRefresh(Overlay &overlay) {
    refresh(overlay);
    HWND windows[] = {overlay.window, overlay.fill, overlay.handle};
    int events = 0;
    for (auto window : windows)
        if (window) {
            UpdateWindow(window);
            SetWindowSubclass(window, countRenderEvents, 2, (DWORD_PTR)&events);
        }
    for (int i = 0; i < 20; ++i) {
        refresh(overlay);
        for (auto window : windows)
            if (window)
                UpdateWindow(window);
    }
    assert(events == 0); // Idle/hover refresh must not re-show, re-position or repaint surfaces.
    for (auto window : windows)
        if (window)
            RemoveWindowSubclass(window, countRenderEvents, 2);
}
struct ResizeRoute {
    LRESULT hit{};
    POINT point{};
};
LRESULT CALLBACK observeResize(HWND window, UINT message, WPARAM w, LPARAM l, UINT_PTR, DWORD_PTR data) {
    if (message == WM_NCLBUTTONDOWN) {
        auto &route = *(ResizeRoute *)data;
        route.hit = w;
        route.point = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
        return 0; // Inspect the real forwarding path without entering a modal mouse drag.
    }
    return DefSubclassProc(window, message, w, l);
}
void checkResizeParity(Overlay &item) {
    struct Sample {
        double x, y;
        LRESULT hit;
    };
    const Sample samples[] = {{21, 21, HTTOPLEFT},   {22, 21, HTCLIENT},      {11, 22, HTLEFT},
                              {12, 100, HTCLIENT},   {100, 11, HTTOP},        {100, 12, HTCLIENT},
                              {639, 21, HTTOPRIGHT}, {618, 21, HTTOPRIGHT},   {639, 100, HTRIGHT},
                              {627, 100, HTCLIENT},  {21, 359, HTBOTTOMLEFT}, {21, 338, HTBOTTOMLEFT},
                              {100, 348, HTBOTTOM},  {100, 347, HTCLIENT},    {618, 338, HTBOTTOMRIGHT},
                              {320, 180, HTCLIENT},  {-1, 100, HTNOWHERE}};
    for (const auto &sample : samples)
        assert(resizeHitAtPoint(sample.x, sample.y, 640, 360) == sample.hit);
    // 150% and 200% screens, including a monitor left of the primary monitor.
    RECT scaled{-960, -300, 0, 240};
    assert(resizeHitInScreenRect(scaled, {-929, -269}, 144) == HTTOPLEFT);
    assert(resizeHitInScreenRect(scaled, {-927, -269}, 144) == HTCLIENT);
    assert(resizeHitInScreenRect(scaled, {-943, -150}, 144) == HTLEFT);
    assert(resizeHitInScreenRect(scaled, {-942, -150}, 144) == HTCLIENT);
    scaled = {-1280, 0, 0, 720};
    assert(resizeHitInScreenRect(scaled, {-1237, 43}, 192) == HTTOPLEFT);
    assert(resizeHitInScreenRect(scaled, {-1236, 43}, 192) == HTCLIENT);
    assert(resizeHitInScreenRect(scaled, {-1257, 200}, 192) == HTLEFT);
    assert(resizeHitInScreenRect(scaled, {-1256, 200}, 192) == HTCLIENT);
    RECT outer{};
    GetWindowRect(item.window, &outer);
    auto dpi = GetDpiForWindow(item.window);
    ResizeRoute route;
    SetWindowSubclass(item.window, observeResize, 1, (DWORD_PTR)&route);
    auto click = [&](int x, int y) {
        POINT screen{outer.left + MulDiv(x, dpi, 96), outer.top + MulDiv(y, dpi, 96)};
        POINT local = screen;
        ScreenToClient(item.fill, &local);
        route = {};
        SendMessageW(item.fill, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(local.x, local.y));
        if (route.hit)
            assert(route.point.x == screen.x && route.point.y == screen.y);
    };
    click(21, 21);
    assert(route.hit == HTTOPLEFT);
    click(100, 10);
    assert(route.hit == HTTOP);
    click(10, 100);
    assert(route.hit == HTLEFT);
    click(100, 100);
    assert(route.hit == HTCAPTION);
    item.source = item.window;
    click(10, 100);
    assert(route.hit == 0);
    item.source = nullptr;
    RemoveWindowSubclass(item.window, observeResize, 1);
    MINMAXINFO limits{};
    SendMessageW(item.window, WM_GETMINMAXINFO, 0, (LPARAM)&limits);
    assert(limits.ptMinTrackSize.x == MulDiv(160, dpi, 96) &&
           limits.ptMinTrackSize.y == MulDiv(100, dpi, 96));
}
void checkNestedElementSelection() {
    WNDCLASSW cls{};
    cls.hInstance = app->instance;
    cls.lpfnWndProc = DefWindowProcW;
    cls.lpszClassName = L"PNClipElementFixture";
    RegisterClassW(&cls);
    HWND source =
        CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, L"Element fixture", WS_POPUP | WS_VISIBLE, 100,
                        100, 500, 400, nullptr, nullptr, app->instance, nullptr);
    // More siblings than the old traversal budget, followed by a nested control.
    for (int i = 0; i < 100; ++i)
        CreateWindowW(L"BUTTON", L"Sibling", WS_CHILD | WS_VISIBLE, 5, 5, 40, 20, source, nullptr,
                      app->instance, nullptr);
    HWND panel = CreateWindowW(cls.lpszClassName, L"Panel", WS_CHILD | WS_VISIBLE, 100, 100, 300, 200, source,
                               nullptr, app->instance, nullptr);
    HWND button = CreateWindowW(L"BUTTON", L"Nested button", WS_CHILD | WS_VISIBLE, 30, 40, 120, 30, panel,
                                nullptr, app->instance, nullptr);
    RECT expected{}, bounds{};
    GetWindowRect(button, &expected);
    GetWindowRect(source, &bounds);
    POINT point{expected.left + 10, expected.top + 10};
    // A selection overlay must not intercept the source-rooted element lookup.
    startSelection();
    auto result = elementAt(source, point, bounds);
    assert(EqualRect(&result, &expected));
    winrt::check_hresult(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                                          __uuidof(IUIAutomation), app->automation.put_void()));
    result = elementAt(source, point, bounds);
    assert(EqualRect(&result, &expected));
    app->automation = nullptr;
    endSelection();
    DestroyWindow(source);
    std::cout << "PASS: nested UI control beyond 80 siblings beneath selection overlay\n";
}
void checkBrowserImageSelection() {
    HWND browser{};
    EnumWindows(
        [](HWND window, LPARAM data) -> BOOL {
            wchar_t title[256]{};
            GetWindowTextW(window, title, 256);
            if (IsWindowVisible(window) && wcsstr(title, L"PNClip Browser Image Fixture")) {
                *(HWND *)data = window;
                return FALSE;
            }
            return TRUE;
        },
        (LPARAM)&browser);
    assert(browser);
    RECT bounds = windowBounds(browser);
    std::cout << "Browser: " << bounds.left << ',' << bounds.top << ',' << bounds.right << ',' << bounds.bottom << std::endl;
    EnumChildWindows(browser, [](HWND w, LPARAM) -> BOOL {
        wchar_t cls[256]{};
        GetClassNameW(w, cls, 256);
        RECT r{}; GetWindowRect(w, &r);
        std::wcout << cls << L" " << r.left << L"," << r.top << L"," << r.right << L"," << r.bottom << std::endl;
        return TRUE;
    }, 0);
    const int expectedWidth = MulDiv(160, GetDpiForWindow(browser), 96);
    const int expectedHeight = MulDiv(90, GetDpiForWindow(browser), 96);
    winrt::check_hresult(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                                          __uuidof(IUIAutomation), app->automation.put_void()));
    startSelection();
    bool found = false;
    for (int attempt = 0; attempt < 3 && !found; ++attempt) {
        for (int y = bounds.top + 100; y < bounds.top + 450 && !found; y += 40) {
            for (int x = bounds.left + 100; x < bounds.left + 400 && !found; x += 40) {
                auto r = elementAt(browser, {x, y}, bounds);
                if (attempt == 0 && x == bounds.left + 180)
                    std::cout << "Hit " << x << ',' << y << ": " << r.left << ',' << r.top << ',' << r.right << ',' << r.bottom << std::endl;
                found = r.right - r.left == expectedWidth && r.bottom - r.top == expectedHeight;
                if (found)
                    std::cout << "Browser image bounds: " << r.left << ',' << r.top << ' ' << r.right - r.left
                              << 'x' << r.bottom - r.top << '\n';
            }
        }
        pumpSelectionMessages();
    }
    endSelection();
    assert(found);
    std::cout << "PASS: real browser image bounds beneath selection overlay\n";
}
int main(int argc, char **argv) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    winrt::init_apartment(winrt::apartment_type::single_threaded);
    App state;
    app = &state;
    state.instance = GetModuleHandleW(nullptr);
    auto registerClass = [&](const wchar_t *name, WNDPROC proc) {
        WNDCLASSW cls{};
        cls.hInstance = state.instance;
        cls.lpfnWndProc = proc;
        cls.lpszClassName = name;
        RegisterClassW(&cls);
    };
    registerClass(L"PNClipHub", hubProc);
    registerClass(L"PNClipOverlay", overlayProc);
    registerClass(L"PNClipFill", fillProc);
    registerClass(L"PNClipHandle", handleProc);
    registerClass(L"PNClipSelection", selectionProc);
    registerClass(L"PNClipOpacity", opacityProc);
    registerClass(L"PNClipLicense", licenseProc);
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_BAR_CLASSES};
    InitCommonControlsEx(&controls);
    state.hub = CreateWindowW(L"PNClipHub", L"UI test", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
                              state.instance, nullptr);
    if (argc > 1 && std::string(argv[1]) == "--browser-image") {
        checkBrowserImageSelection();
        DestroyWindow(state.hub);
        return 0;
    }
    checkNestedElementSelection();
    createOverlay({150, 150, 790, 510});
    assert(state.overlays.size() == 1);
    auto *item = state.current();
    assert(item && IsWindowVisible(item->window) && IsWindowVisible(item->fill));
    auto content = contentBounds(item->window);
    assert(content.right - content.left == 640 && content.bottom - content.top == 360);
    RECT outline{};
    GetWindowRect(item->window, &outline);
    assert(content.left - outline.left == 4 && content.top - outline.top == 4);
    assert(outline.right - content.right == 4 && outline.bottom - content.bottom == 4);
    assert(!(GetWindowLongPtrW(item->window, GWL_EXSTYLE) & WS_EX_APPWINDOW));
    auto popup = buildTrayMenu();
    auto file = GetSubMenu(popup, 2), captureMenu = GetSubMenu(popup, 3), view = GetSubMenu(popup, 4);
    assert(file && captureMenu && view);
    assert(GetMenuItemID(file, 0) == New && GetMenuItemID(captureMenu, 0) == Still);
    assert(GetMenuItemID(view, 0) == Transparency);
    assert(GetMenuState(popup, Licenses, MF_BYCOMMAND) != UINT(-1));
    assert(GetMenuState(popup, Quit, MF_BYCOMMAND) != UINT(-1));
    DestroyMenu(popup);
    DWORD affinity{};
    assert(GetWindowDisplayAffinity(item->window, &affinity) && affinity == WDA_EXCLUDEFROMCAPTURE);
    auto target = targetFor(*item);
    assert(target.valid() && target.excludedWindows.size() == 2);
    RECT frame{};
    GetWindowRect(item->window, &frame);
    auto hit = SendMessageW(item->window, WM_NCHITTEST, 0, MAKELPARAM(frame.left + 1, frame.top + 1));
    assert(hit == HTTOPLEFT);
    checkResizeParity(*item);
    execute(PassThrough);
    assert(item->pass);
    execute(Opacity50);
    assert(item->opacity == 128);
    execute(Transparency);
    assert(IsWindow(state.opacityWindow) && IsWindow(state.opacitySlider));
    SendMessageW(state.opacitySlider, TBM_SETPOS, TRUE, 80);
    SendMessageW(state.opacityWindow, WM_HSCROLL, TB_THUMBPOSITION, (LPARAM)state.opacitySlider);
    assert(item->opacity == 51);
    DestroyWindow(state.opacityWindow);
    execute(Licenses);
    assert(IsWindow(state.licenseWindow) && GetWindowTextLengthW(GetDlgItem(state.licenseWindow, 1)) > 1000);
    DestroyWindow(state.licenseWindow);
    // Capture only our own overlay surface for visual inspection (no desktop pixels).
    UpdateWindow(item->window);
    auto dc = GetDC(item->window);
    auto memory = CreateCompatibleDC(dc);
    const int width = frame.right - frame.left, height = frame.bottom - frame.top;
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    void *pixels{};
    auto bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    auto old = SelectObject(memory, bitmap);
    assert(PrintWindow(item->window, memory, PW_CLIENTONLY));
    PixelBuffer preview{(unsigned)width, (unsigned)height, (unsigned)width * 4, PixelFormat::bgra8,
                        std::vector<std::byte>((size_t)width * height * 4)};
    std::memcpy(preview.bytes.data(), pixels, preview.bytes.size());
    for (size_t i = 3; i < preview.bytes.size(); i += 4)
        preview.bytes[i] = std::byte{255};
    CaptureSettings output;
    output.destinationFolder = std::filesystem::current_path() / "test-output";
    output.filenamePrefix = "UI-preview";
    std::filesystem::path path;
    assert(!saveStillWin(preview, output, path).code);
    SelectObject(memory, old);
    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(item->window, dc);
    createOverlay({200, 200, 520, 400}, state.hub);
    auto *attached = state.current();
    auto attachedId = attached->id;
    assert(IsWindowVisible(attached->handle));
    checkStableRefresh(*attached);
    RECT handleRect{}, attachedRect{};
    GetWindowRect(attached->handle, &handleRect);
    GetWindowRect(attached->window, &attachedRect);
    assert(handleRect.left == attachedRect.right && handleRect.top == attachedRect.top);
    assert(handleRect.right - handleRect.left == MulDiv(14, GetDpiForWindow(attached->window), 96));
    DWORD handleAffinity{};
    assert(GetWindowDisplayAffinity(attached->handle, &handleAffinity) &&
           handleAffinity == WDA_EXCLUDEFROMCAPTURE);
    assert(GetWindowLongPtrW(attached->fill, GWL_EXSTYLE) & WS_EX_TRANSPARENT);
    RECT beforeDetach = contentBounds(attached->window);
    popup = buildTrayMenu();
    DestroyMenu(popup);
    state.selected = item->window;
    auto selectedIndex =
        std::find(state.menuWindows.begin(), state.menuWindows.end(), attachedId) - state.menuWindows.begin();
    execute(windowCommandBase + static_cast<int>(selectedIndex));
    assert(state.current() == attached);
    execute(Detach);
    RECT afterDetach = contentBounds(attached->window);
    assert(!attached->source && EqualRect(&beforeDetach, &afterDetach));
    assert(!IsWindowVisible(attached->handle));
    assert(!(GetWindowLongPtrW(attached->fill, GWL_EXSTYLE) & WS_EX_TRANSPARENT));
    assert(state.overlays.size() == 2);
    execute(Close);
    assert(state.overlays.size() == 1 && state.current());
    startSelection();
    assert(state.selector && GetCapture() != state.selector);
    endSelection();
    assert(!state.selector && IsWindowVisible(state.current()->window));
    checkNativeSelectionDrag();
    execute(CloseAll);
    assert(state.overlays.empty() && !state.selected && IsWindow(state.hub));
    state.tray.cbSize = sizeof(state.tray);
    state.tray.hWnd = state.hub;
    state.tray.uID = 1;
    state.tray.uFlags = NIF_ICON | NIF_TIP;
    state.tray.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcscpy_s(state.tray.szTip, L"PNClip tray lifecycle test");
    state.trayRegistered = Shell_NotifyIconW(NIM_ADD, &state.tray) != FALSE;
    assert(state.trayRegistered);
    assert(Shell_NotifyIconW(NIM_DELETE, &state.tray));
    SendMessageW(state.hub, WM_TIMER, 1, 0);
    assert(state.closing && !state.capture && !state.trayRegistered && !IsWindow(state.hub));
    std::cout << "PASS: overlay creation, sizing, exclusion, hit testing, transparency, multi-window "
                 "closing, selection capture, Mac menu layout and shutdown after tray removal\n";
    std::wcout << L"UI preview: " << path.wstring() << L'\n';
}
