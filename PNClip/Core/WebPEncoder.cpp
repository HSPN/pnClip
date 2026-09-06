#include "WebPEncoder.hpp"
#include <webp/encode.h>
#include <webp/mux.h>
#include <cstring>
namespace pnclip {
EncodeResult WebPEncoder::encode(std::span<const PixelBuffer> frames,
    std::span<const std::chrono::milliseconds> durations) const {
    if (frames.empty() || frames.size() != durations.size()) return {{}, {1, "No frames"}};
    const auto width = frames.front().width, height = frames.front().height;
    if (!frames.front().valid() || width > WEBP_MAX_DIMENSION || height > WEBP_MAX_DIMENSION)
        return {{}, {2, "Unsupported dimensions"}};
    for (const auto& frame : frames)
        if (!frame.valid() || frame.width != width || frame.height != height)
            return {{}, {3, "Frame dimensions differ"}};
    WebPAnimEncoderOptions options;
    if (!WebPAnimEncoderOptionsInit(&options)) return {{}, {4, "Options failed"}};
    options.anim_params.loop_count = 0;
    auto* encoder = WebPAnimEncoderNew((int)width, (int)height, &options);
    if (!encoder) return {{}, {5, "Encoder creation failed"}};
    WebPConfig config;
    if (!WebPConfigInit(&config)) { WebPAnimEncoderDelete(encoder); return {{}, {6, "Config failed"}}; }
    config.lossless = 0; config.quality = 90; config.method = 4;
    config.thread_level = 1; config.use_sharp_yuv = 1;
    int timestamp = 0; bool success = true;
    for (std::size_t i = 0; i < frames.size() && success; ++i) {
        WebPPicture picture;
        success = WebPPictureInit(&picture);
        if (!success) break;
        picture.use_argb = 1; picture.width = (int)width; picture.height = (int)height;
        const auto* bytes = reinterpret_cast<const std::uint8_t*>(frames[i].bytes.data());
        success = (frames[i].format == PixelFormat::rgba8
            ? WebPPictureImportRGBA(&picture, bytes, (int)frames[i].stride)
            : WebPPictureImportBGRA(&picture, bytes, (int)frames[i].stride));
        success = success && WebPAnimEncoderAdd(encoder, &picture, timestamp, &config);
        WebPPictureFree(&picture);
        timestamp += (int)durations[i].count();
    }
    if (success) success = WebPAnimEncoderAdd(encoder, nullptr, timestamp, nullptr);
    WebPData output; WebPDataInit(&output);
    if (success) success = WebPAnimEncoderAssemble(encoder, &output);
    std::string message = success ? "" : (WebPAnimEncoderGetError(encoder) ?: "Encoding failed");
    WebPAnimEncoderDelete(encoder);
    if (!success) { WebPDataClear(&output); return {{}, {7, std::move(message)}}; }
    std::vector<std::byte> data(output.size);
    std::memcpy(data.data(), output.bytes, output.size);
    WebPDataClear(&output);
    return {std::move(data), {}};
}
}
