#import "MainMenuBuilder.h"
#import "AppDelegate.h"

NSMenu *PNClipCreateMainMenu(AppDelegate *delegate) {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"PNClip"];
    NSMenuItem *launchAtLogin = [[NSMenuItem alloc] initWithTitle:@"로그인 시 실행"
        action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    launchAtLogin.target = delegate;
    delegate.launchAtLoginItem = launchAtLogin;
    [appMenu addItem:launchAtLogin];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"PNClip 종료" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;

    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:fileMenuItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"파일"];
    NSMenuItem *newWindow = [[NSMenuItem alloc] initWithTitle:@"새 창"
        action:@selector(newWindow:) keyEquivalent:@"n"];
    newWindow.target = delegate;
    [fileMenu addItem:newWindow];
    NSMenuItem *closeWindow = [[NSMenuItem alloc] initWithTitle:@"창 닫기"
        action:@selector(closeCurrentWindow:) keyEquivalent:@"w"];
    closeWindow.target = delegate;
    [fileMenu addItem:closeWindow];
    NSMenuItem *closeAll = [[NSMenuItem alloc] initWithTitle:@"모든 창 닫기"
        action:@selector(closeAllWindows:) keyEquivalent:@"w"];
    closeAll.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    closeAll.target = delegate;
    [fileMenu addItem:closeAll];
    [fileMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *openRecent = [[NSMenuItem alloc] initWithTitle:@"최근 캡처 열기"
        action:@selector(openMostRecentCapture:) keyEquivalent:@"o"];
    openRecent.target = delegate;
    [fileMenu addItem:openRecent];
    NSMenuItem *openFolder = [[NSMenuItem alloc] initWithTitle:@"저장 폴더 열기"
        action:@selector(openSaveDirectory:) keyEquivalent:@"o"];
    openFolder.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    openFolder.target = delegate;
    [fileMenu addItem:openFolder];
    [fileMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *saveLocation = [[NSMenuItem alloc] initWithTitle:@"저장 위치 변경…"
        action:@selector(chooseSaveLocation:) keyEquivalent:@""];
    saveLocation.target = delegate;
    [fileMenu addItem:saveLocation];
    NSMenuItem *filenamePrefix = [[NSMenuItem alloc] initWithTitle:@"저장 파일명…"
        action:@selector(changeFilenamePrefix:) keyEquivalent:@""];
    filenamePrefix.target = delegate;
    [fileMenu addItem:filenamePrefix];
    fileMenuItem.submenu = fileMenu;

    NSMenuItem *captureMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:captureMenuItem];
    NSMenu *captureMenu = [[NSMenu alloc] initWithTitle:@"캡처"];
    NSMenuItem *capture = [[NSMenuItem alloc] initWithTitle:@"캡처"
        action:@selector(capture:) keyEquivalent:@"s"];
    capture.target = delegate;
    [captureMenu addItem:capture];
    NSMenuItem *record = [[NSMenuItem alloc] initWithTitle:@"화면 녹화 시작/중지"
        action:@selector(toggleRecording:) keyEquivalent:@"r"];
    record.target = delegate;
    [captureMenu addItem:record];
    NSMenuItem *rolling = [[NSMenuItem alloc] initWithTitle:@"최근 GIF 상시 녹화"
        action:@selector(toggleRollingRecording:) keyEquivalent:@"r"];
    rolling.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    rolling.target = delegate;
    delegate.rollingRecordingItem = rolling;
    [captureMenu addItem:rolling];
    [captureMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *durationItem = [[NSMenuItem alloc] initWithTitle:@"GIF 길이"
        action:nil keyEquivalent:@""];
    NSMenu *durationMenu = [[NSMenu alloc] initWithTitle:@"GIF 길이"];
    durationMenu.autoenablesItems = NO;
    NSMenuItem *fiveSeconds = [[NSMenuItem alloc] initWithTitle:@"5초"
        action:@selector(selectRecordingDuration:) keyEquivalent:@""];
    fiveSeconds.tag = 5;
    fiveSeconds.target = delegate;
    fiveSeconds.state = NSControlStateValueOn;
    delegate.fiveSecondItem = fiveSeconds;
    [durationMenu addItem:fiveSeconds];
    NSMenuItem *tenSeconds = [[NSMenuItem alloc] initWithTitle:@"10초"
        action:@selector(selectRecordingDuration:) keyEquivalent:@""];
    tenSeconds.tag = 10;
    tenSeconds.target = delegate;
    delegate.tenSecondItem = tenSeconds;
    [durationMenu addItem:tenSeconds];
    durationItem.submenu = durationMenu;
    [captureMenu addItem:durationItem];

    NSMenuItem *scaleItem = [[NSMenuItem alloc] initWithTitle:@"GIF 해상도"
        action:nil keyEquivalent:@""];
    NSMenu *scaleMenu = [[NSMenu alloc] initWithTitle:@"GIF 해상도"];
    scaleMenu.autoenablesItems = NO;
    NSMenuItem *standardScale = [[NSMenuItem alloc] initWithTitle:@"일반"
        action:@selector(selectRecordingScale:) keyEquivalent:@""];
    standardScale.tag = 1;
    standardScale.target = delegate;
    standardScale.state = NSControlStateValueOn;
    delegate.standardScaleItem = standardScale;
    [scaleMenu addItem:standardScale];
    NSMenuItem *retinaScale = [[NSMenuItem alloc] initWithTitle:@"Retina"
        action:@selector(selectRecordingScale:) keyEquivalent:@""];
    retinaScale.tag = 2;
    retinaScale.target = delegate;
    delegate.retinaScaleItem = retinaScale;
    [scaleMenu addItem:retinaScale];
    scaleItem.submenu = scaleMenu;
    [captureMenu addItem:scaleItem];
    [captureMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *mouseInput = [[NSMenuItem alloc] initWithTitle:@"녹화 중 마우스 입력"
        action:@selector(toggleRecordingMouseInput:) keyEquivalent:@""];
    mouseInput.target = delegate;
    mouseInput.state = NSControlStateValueOff;
    delegate.recordingMouseInputItem = mouseInput;
    [captureMenu addItem:mouseInput];
    captureMenuItem.submenu = captureMenu;

    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:viewMenuItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"보기"];
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 250, 48)];
    NSTextField *label = [NSTextField labelWithString:@"중앙 투명도"];
    label.frame = NSMakeRect(12, 25, 100, 18);
    [container addSubview:label];
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(108, 20, 130, 24)];
    slider.minValue = 0.0;
    slider.maxValue = 100.0;
    slider.doubleValue = 80.0;
    slider.continuous = YES;
    slider.target = delegate;
    slider.action = @selector(transparencyChanged:);
    delegate.transparencySlider = slider;
    [container addSubview:slider];
    NSMenuItem *sliderItem = [[NSMenuItem alloc] init];
    sliderItem.view = container;
    [viewMenu addItem:sliderItem];
    viewMenuItem.submenu = viewMenu;

    NSMenuItem *estimatedSize = [[NSMenuItem alloc] initWithTitle:@"예상 GIF: 계산 중…"
        action:nil keyEquivalent:@""];
    estimatedSize.submenu = [[NSMenu alloc] initWithTitle:estimatedSize.title];
    estimatedSize.enabled = NO;
    estimatedSize.hidden = YES;
    delegate.estimatedSizeItem = estimatedSize;
    [mainMenu addItem:estimatedSize];
    return mainMenu;
}
