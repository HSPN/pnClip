#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "PlatformServicesMac.hpp"

namespace pnclip {
namespace {
class StartupBackendMac final : public StartupBackend {
public:
    bool enabled() const override {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    bool setEnabled(bool enabled) override {
        NSError *error = nil;
        SMAppService *service = SMAppService.mainAppService;
        const bool ok = enabled ? [service registerAndReturnError:&error]
                                : [service unregisterAndReturnError:&error];
        return ok && error == nil;
    }
    bool requiresApproval() const override {
        return SMAppService.mainAppService.status == SMAppServiceStatusRequiresApproval;
    }
    void openApprovalSettings() override { [SMAppService openSystemSettingsLoginItems]; }
};
class ShellBackendMac final : public ShellBackend {
public:
    bool open(const std::filesystem::path& path) override {
        if (path.empty()) return false;
        NSURL *url = [NSURL fileURLWithFileSystemRepresentation:path.c_str()
            isDirectory:NO relativeToURL:nil];
        return [NSWorkspace.sharedWorkspace openURL:url];
    }
};
class ClipboardBackendMac final : public ClipboardBackend {
public:
    bool copyImage(const PixelBuffer&, CaptureFormat, const std::filesystem::path& path) override {
        return copyFile(path);
    }
    bool copyFile(const std::filesystem::path& path) override {
        if (path.empty()) return false;
        NSURL *url = [NSURL fileURLWithFileSystemRepresentation:path.c_str()
            isDirectory:NO relativeToURL:nil];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (!data) return false;
        NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
        UTType *type = [UTType typeWithFilenameExtension:url.pathExtension];
        if (type) [item setData:data forType:(NSPasteboardType)type.identifier];
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (image.TIFFRepresentation) [item setData:image.TIFFRepresentation forType:NSPasteboardTypeTIFF];
        [item setString:url.absoluteString forType:NSPasteboardTypeFileURL];
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        return [pasteboard writeObjects:@[item]];
    }
};
}
std::unique_ptr<StartupBackend> makeStartupBackendMac() { return std::make_unique<StartupBackendMac>(); }
std::unique_ptr<ShellBackend> makeShellBackendMac() { return std::make_unique<ShellBackendMac>(); }
std::unique_ptr<ClipboardBackend> makeClipboardBackendMac() { return std::make_unique<ClipboardBackendMac>(); }
}
