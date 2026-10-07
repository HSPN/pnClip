#include "../PNClip/Capture/CaptureBackendWin.hpp"
#include "../PNClip/Core/GifEncoder.hpp"
#include "../PNClip/Core/WebPEncoder.hpp"
#include "../PNClip/Support/ImageFilesWin.hpp"
#include <cassert>
#include <fstream>
#include <future>
#include <iostream>
#include <webp/demux.h>
#include <wincodec.h>
#include <winrt/base.h>
using namespace pnclip;
using namespace std::chrono_literals;
void checkImage(const std::filesystem::path &path, unsigned count, unsigned width, unsigned height) {
    auto factory = winrt::create_instance<IWICImagingFactory>(CLSID_WICImagingFactory);
    winrt::com_ptr<IWICBitmapDecoder> decoder;
    winrt::check_hresult(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                                            WICDecodeMetadataCacheOnLoad, decoder.put()));
    UINT frames = 0;
    winrt::check_hresult(decoder->GetFrameCount(&frames));
    assert(frames == count);
    for (unsigned i = 0; i < count; ++i) {
        winrt::com_ptr<IWICBitmapFrameDecode> frame;
        winrt::check_hresult(decoder->GetFrame(i, frame.put()));
        UINT w = 0, h = 0;
        frame->GetSize(&w, &h);
        assert(w == width && h == height);
        winrt::com_ptr<IWICFormatConverter> converter;
        factory->CreateFormatConverter(converter.put());
        winrt::check_hresult(converter->Initialize(frame.get(), GUID_WICPixelFormat32bppBGRA,
                                                   WICBitmapDitherTypeNone, nullptr, 0,
                                                   WICBitmapPaletteTypeCustom));
        std::vector<BYTE> pixels((size_t)w * h * 4);
        winrt::check_hresult(converter->CopyPixels(nullptr, w * 4, (UINT)pixels.size(), pixels.data()));
        assert(pixels[2] > 180);
    }
}
void runCaptureTests();
void checkGifColorQuality() {
    PixelBuffer source{256,128,256*4,PixelFormat::bgra8,std::vector<std::byte>(256*128*4)};
    for(unsigned y=0;y<source.height;++y)for(unsigned x=0;x<source.width;++x) {
        auto offset=(size_t)y*source.stride+x*4;
        source.bytes[offset]=std::byte(x);
        source.bytes[offset+1]=std::byte(y<64?x:64+y/2);
        source.bytes[offset+2]=std::byte(y<64?x:32+x/4);
        source.bytes[offset+3]=std::byte{255};
    }
    CaptureSettings settings;settings.destinationFolder=std::filesystem::current_path()/"test-output";
    settings.filenamePrefix="GIF-color-restored";
    std::filesystem::path path;assert(!saveAnimationWin({source},{40ms},settings,path).code);
    auto factory=winrt::create_instance<IWICImagingFactory>(CLSID_WICImagingFactory);
    winrt::com_ptr<IWICBitmapDecoder> decoder;
    winrt::check_hresult(factory->CreateDecoderFromFilename(path.c_str(),nullptr,GENERIC_READ,WICDecodeMetadataCacheOnLoad,decoder.put()));
    winrt::com_ptr<IWICBitmapFrameDecode> frame;winrt::check_hresult(decoder->GetFrame(0,frame.put()));
    winrt::com_ptr<IWICFormatConverter> converter;factory->CreateFormatConverter(converter.put());
    winrt::check_hresult(converter->Initialize(frame.get(),GUID_WICPixelFormat32bppBGRA,WICBitmapDitherTypeNone,nullptr,0,WICBitmapPaletteTypeCustom));
    auto restored=source;winrt::check_hresult(converter->CopyPixels(nullptr,restored.stride,(UINT)restored.bytes.size(),(BYTE*)restored.bytes.data()));
    double previousError=0,currentError=0;
    for(size_t i=0;i<source.bytes.size();i+=4)for(int c=0;c<3;++c) {
        const int value=std::to_integer<int>(source.bytes[i+c]);
        const int previous=c==0?(value>>6)*255/3:(value>>5)*255/7;
        const int actual=std::to_integer<int>(restored.bytes[i+c]);
        previousError+=(value-previous)*(value-previous);currentError+=(value-actual)*(value-actual);
        if(i<64*source.stride)assert(std::abs(value-actual)<=5);
    }
    assert(currentError<previousError*0.5);
    // Windows BGRA and Mac RGBA must encode the exact same palette and pixels.
    auto rgba=source;rgba.format=PixelFormat::rgba8;
    for(size_t i=0;i<rgba.bytes.size();i+=4)std::swap(rgba.bytes[i],rgba.bytes[i+2]);
    std::array durations{40ms};
    auto bgraResult=GifEncoder{}.encode(std::span(&source,1),durations);
    auto rgbaResult=GifEncoder{}.encode(std::span(&rgba,1),durations);
    assert(bgraResult&&rgbaResult&&bgraResult.data==rgbaResult.data);
    auto pixels=source.width*source.height*3;
    std::cout<<"GIF decoded color MSE: old "<<previousError/pixels<<", restored "<<currentError/pixels<<"; RGBA/BGRA output identical\n";
}
void checkWebP(const std::filesystem::path &path, unsigned expectedFrames) {
    std::ifstream input(path, std::ios::binary);
    std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(input)), {});
    WebPData data{bytes.data(), bytes.size()};
    auto *decoder = WebPAnimDecoderNew(&data, nullptr);
    assert(decoder);
    WebPAnimInfo info{};
    assert(WebPAnimDecoderGetInfo(decoder, &info));
    assert(info.canvas_width == 32 && info.canvas_height == 24 && info.frame_count == expectedFrames);
    unsigned count = 0;
    int previous = 0;
    while (WebPAnimDecoderHasMoreFrames(decoder)) {
        uint8_t *pixels{};
        int timestamp = 0;
        assert(WebPAnimDecoderGetNext(decoder, &pixels, &timestamp));
        // A still WebP has no animation duration; its timestamp is zero.
        assert(pixels && (expectedFrames == 1 ? timestamp >= previous : timestamp > previous));
        previous = timestamp;
        ++count;
    }
    assert(count == expectedFrames);
    WebPAnimDecoderDelete(decoder);
}
int main(int argc, char **) {
    winrt::init_apartment();
    checkGifColorQuality();
    PixelBuffer image{32, 24, 128, PixelFormat::bgra8, std::vector<std::byte>(32 * 24 * 4)};
    for (size_t i = 0; i < image.bytes.size(); i += 4) {
        image.bytes[i + 2] = std::byte{255};
        image.bytes[i + 3] = std::byte{255};
    }
    CaptureSettings settings;
    settings.destinationFolder = std::filesystem::current_path() / "test-output";
    settings.filenamePrefix = "한글:test";
    std::filesystem::path path;
    auto error = saveStillWin(image, settings, path);
    assert(!error.code);
    checkImage(path, 1, 32, 24);
    auto resized = resizeImageWin(image, 16, 12);
    assert(resized.valid() && resized.width == 16 && resized.height == 12);
    error = saveAnimationWin({image, image}, {40ms, 80ms}, settings, path);
    assert(!error.code);
    checkImage(path, 2, 32, 24);
    settings.format = CaptureFormat::webP;
    error = saveStillWin(image, settings, path);
    assert(!error.code && std::filesystem::file_size(path) > 20);
    checkWebP(path, 1);
    auto blue = image;
    for (size_t i = 0; i < blue.bytes.size(); i += 4) {
        blue.bytes[i] = std::byte{255};
        blue.bytes[i + 2] = std::byte{0};
    }
    error = saveAnimationWin({image, blue}, {40ms, 80ms}, settings, path);
    assert(!error.code);
    checkWebP(path, 2);
    error = saveAnimationWin({image, resized}, {40ms, 80ms}, settings, path);
    assert(error.code && path.empty());
    auto backend = makeCaptureBackendWin();
    std::promise<ServiceError> invalid;
    auto future = invalid.get_future();
    backend->captureStill({}, [&](PixelBuffer, ServiceError e) { invalid.set_value(e); });
    assert(future.wait_for(5s) == std::future_status::ready && future.get().code);
    std::cout
        << "PASS: PNG, GIF and animated WebP re-decode, resize, invalid dimensions and capture target\n";
    if (argc > 1)
        runCaptureTests();
}
