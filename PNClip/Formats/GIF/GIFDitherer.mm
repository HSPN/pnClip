#import "GIFDitherer.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

namespace {
static float SRGBToLinear(uint8_t value) {
    float c = value / 255.0f;
    return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
}

static uint8_t LinearToSRGB(float value) {
    value = std::clamp(value, 0.0f, 1.0f);
    float c = value <= 0.0031308f ? value * 12.92f
                                 : 1.055f * powf(value, 1.0f / 2.4f) - 0.055f;
    return (uint8_t)std::clamp(lroundf(c * 255.0f), 0l, 255l);
}
}

@implementation GIFDitherer {
    std::array<std::array<float, 3>, 256> _linearPalette;
    std::array<uint8_t, 64 * 64 * 64> _nearestColor;
    std::array<float, 256> _srgbToLinear;
    std::array<uint8_t, 4097> _linearToSRGB;
}

- (instancetype)initWithPalette:(NSData *)paletteData {
    self = [super init];
    if (!self) return nil;
    const uint8_t *palette = (const uint8_t *)paletteData.bytes;
    size_t count = std::min<size_t>(256, paletteData.length / 3);
    for (size_t i = 0; i < _srgbToLinear.size(); i++) {
        _srgbToLinear[i] = SRGBToLinear((uint8_t)i);
    }
    for (size_t i = 0; i < _linearToSRGB.size(); i++) {
        _linearToSRGB[i] = LinearToSRGB((float)i / 4096.0f);
    }
    for (size_t i = 0; i < 256; i++) {
        size_t source = count ? i % count : 0;
        _linearPalette[i] = {SRGBToLinear(palette[source * 3]),
                             SRGBToLinear(palette[source * 3 + 1]),
                             SRGBToLinear(palette[source * 3 + 2])};
    }
    for (size_t r = 0; r < 64; r++) {
        for (size_t g = 0; g < 64; g++) {
            for (size_t b = 0; b < 64; b++) {
                float lr = SRGBToLinear((uint8_t)(r * 4 + 2));
                float lg = SRGBToLinear((uint8_t)(g * 4 + 2));
                float lb = SRGBToLinear((uint8_t)(b * 4 + 2));
                size_t nearest = 0;
                float best = INFINITY;
                for (size_t i = 0; i < count; i++) {
                    float dr = lr - _linearPalette[i][0];
                    float dg = lg - _linearPalette[i][1];
                    float db = lb - _linearPalette[i][2];
                    float distance = 0.30f * dr * dr + 0.59f * dg * dg + 0.11f * db * db;
                    if (distance < best) { best = distance; nearest = i; }
                }
                _nearestColor[(r << 12) | (g << 6) | b] = (uint8_t)nearest;
            }
        }
    }
    return self;
}

- (NSData *)indexedPixelsForRGBABytes:(const uint8_t *)bytes
                                width:(size_t)width
                               height:(size_t)height
                          bytesPerRow:(size_t)bytesPerRow {
    NSMutableData *result = [NSMutableData dataWithLength:width * height];
    uint8_t *indices = (uint8_t *)result.mutableBytes;
    std::vector<std::array<float, 3>> current(width + 2, {0, 0, 0});
    std::vector<std::array<float, 3>> next(width + 2, {0, 0, 0});

    for (size_t y = 0; y < height; y++) {
        bool reverse = (y & 1) != 0;
        const uint8_t *row = bytes + y * bytesPerRow;
        for (size_t step = 0; step < width; step++) {
            size_t x = reverse ? width - 1 - step : step;
            size_t errorIndex = x + 1;
            const uint8_t *pixel = row + x * 4;
            float r = std::clamp(_srgbToLinear[pixel[0]] + current[errorIndex][0], 0.0f, 1.0f);
            float g = std::clamp(_srgbToLinear[pixel[1]] + current[errorIndex][1], 0.0f, 1.0f);
            float b = std::clamp(_srgbToLinear[pixel[2]] + current[errorIndex][2], 0.0f, 1.0f);
            uint8_t sr = _linearToSRGB[(size_t)lroundf(r * 4096.0f)];
            uint8_t sg = _linearToSRGB[(size_t)lroundf(g * 4096.0f)];
            uint8_t sb = _linearToSRGB[(size_t)lroundf(b * 4096.0f)];
            size_t lookup = ((size_t)(sr >> 2) << 12) |
                            ((size_t)(sg >> 2) << 6) | (size_t)(sb >> 2);
            uint8_t paletteIndex = _nearestColor[lookup];
            indices[y * width + x] = paletteIndex;
            std::array<float, 3> error = {
                std::clamp(r - _linearPalette[paletteIndex][0], -0.25f, 0.25f),
                std::clamp(g - _linearPalette[paletteIndex][1], -0.25f, 0.25f),
                std::clamp(b - _linearPalette[paletteIndex][2], -0.25f, 0.25f)};
            auto add = [&](std::array<float, 3> &target, float weight) {
                for (int c = 0; c < 3; c++) target[c] += error[c] * weight;
            };
            if (!reverse) {
                add(current[errorIndex + 1], 7.0f / 16.0f);
                add(next[errorIndex - 1], 3.0f / 16.0f);
                add(next[errorIndex], 5.0f / 16.0f);
                add(next[errorIndex + 1], 1.0f / 16.0f);
            } else {
                add(current[errorIndex - 1], 7.0f / 16.0f);
                add(next[errorIndex + 1], 3.0f / 16.0f);
                add(next[errorIndex], 5.0f / 16.0f);
                add(next[errorIndex - 1], 1.0f / 16.0f);
            }
        }
        current.swap(next);
        std::fill(next.begin(), next.end(), std::array<float, 3>{0, 0, 0});
    }
    return result;
}
@end
