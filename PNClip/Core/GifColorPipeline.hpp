#pragma once
// Portable restoration of GIFColorQuantizerMac / GIFDithererMac from the
// pre-platform-refactor Mac encoder. Keep its sampling, weighted median-cut,
// three Lloyd iterations, linear-light lookup and serpentine diffusion rules.
#include <algorithm>
#include <array>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <span>
#include <vector>
namespace pnclip::gif_detail {
constexpr size_t kHistogramSize = 64 * 64 * 64;

struct ColorEntry {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint64_t count;
};

struct ColorBox {
    std::vector<size_t> indices;
    uint8_t minR = 0, maxR = 0, minG = 0, maxG = 0, minB = 0, maxB = 0;
    uint64_t population = 0;
};

static void UpdateBox(ColorBox &box, const std::vector<ColorEntry> &colors) {
    if (box.indices.empty())
        return;
    box.minR = box.minG = box.minB = 255;
    box.maxR = box.maxG = box.maxB = 0;
    box.population = 0;
    for (size_t index : box.indices) {
        const auto &color = colors[index];
        box.minR = std::min(box.minR, color.r);
        box.maxR = std::max(box.maxR, color.r);
        box.minG = std::min(box.minG, color.g);
        box.maxG = std::max(box.maxG, color.g);
        box.minB = std::min(box.minB, color.b);
        box.maxB = std::max(box.maxB, color.b);
        box.population += color.count;
    }
}

static int WidestChannel(const ColorBox &box) {
    int r = box.maxR - box.minR;
    int g = box.maxG - box.minG;
    int b = box.maxB - box.minB;
    return r >= g && r >= b ? 0 : (g >= b ? 1 : 2);
}

static uint8_t ColorComponent(const ColorEntry &entry, int channel) {
    return channel == 0 ? entry.r : (channel == 1 ? entry.g : entry.b);
}
class ColorQuantizer {
    std::vector<uint64_t> _histogram = std::vector<uint64_t>(kHistogramSize, 0);

  public:
    void addRGBABytes(const uint8_t *bytes, size_t width, size_t height, size_t bytesPerRow,
                      size_t sampleStep) {
        sampleStep = std::max<size_t>(1, sampleStep);
        for (size_t y = 0; y < height; y += sampleStep)
            for (size_t x = 0; x < width; x += sampleStep) {
                const auto *pixel = bytes + y * bytesPerRow + x * 4;
                size_t index = ((size_t)(pixel[0] >> 2) << 12) | ((size_t)(pixel[1] >> 2) << 6) |
                               (size_t)(pixel[2] >> 2);
                ++_histogram[index];
            }
    }
    std::vector<uint8_t> makePalette(size_t requestedCount) {
        size_t colorCount = std::max<size_t>(2, std::min<size_t>(256, requestedCount));
        std::vector<ColorEntry> colors;
        colors.reserve(kHistogramSize);
        for (size_t i = 0; i < _histogram.size(); i++) {
            uint64_t count = _histogram[i];
            if (!count)
                continue;
            colors.push_back({(uint8_t)((((i >> 12) & 63) << 2) | 2), (uint8_t)((((i >> 6) & 63) << 2) | 2),
                              (uint8_t)(((i & 63) << 2) | 2), count});
        }

        std::vector<uint8_t> result(colorCount * 3);
        uint8_t *palette = result.data();
        if (colors.empty())
            return result;

        ColorBox initial;
        initial.indices.resize(colors.size());
        for (size_t i = 0; i < colors.size(); i++)
            initial.indices[i] = i;
        UpdateBox(initial, colors);
        std::vector<ColorBox> boxes;
        boxes.push_back(std::move(initial));

        while (boxes.size() < colorCount) {
            auto candidate = boxes.end();
            uint64_t bestScore = 0;
            for (auto it = boxes.begin(); it != boxes.end(); ++it) {
                if (it->indices.size() < 2)
                    continue;
                uint64_t range = std::max({it->maxR - it->minR, it->maxG - it->minG, it->maxB - it->minB});
                uint64_t score = range * it->population;
                if (score > bestScore) {
                    bestScore = score;
                    candidate = it;
                }
            }
            if (candidate == boxes.end())
                break;

            int channel = WidestChannel(*candidate);
            std::sort(candidate->indices.begin(), candidate->indices.end(), [&](size_t a, size_t b) {
                return ColorComponent(colors[a], channel) < ColorComponent(colors[b], channel);
            });
            uint64_t half = candidate->population / 2;
            uint64_t accumulated = 0;
            size_t split = 1;
            for (; split < candidate->indices.size(); split++) {
                accumulated += colors[candidate->indices[split - 1]].count;
                if (accumulated >= half)
                    break;
            }
            split = std::min(split, candidate->indices.size() - 1);
            ColorBox second;
            second.indices.assign(candidate->indices.begin() + split, candidate->indices.end());
            candidate->indices.erase(candidate->indices.begin() + split, candidate->indices.end());
            UpdateBox(*candidate, colors);
            UpdateBox(second, colors);
            boxes.push_back(std::move(second));
        }

        std::vector<std::array<double, 3>> centers;
        centers.reserve(colorCount);
        for (const ColorBox &box : boxes) {
            double r = 0, g = 0, b = 0;
            uint64_t total = 0;
            for (size_t index : box.indices) {
                const auto &color = colors[index];
                r += color.r * color.count;
                g += color.g * color.count;
                b += color.b * color.count;
                total += color.count;
            }
            centers.push_back({r / total, g / total, b / total});
        }

        // A few weighted Lloyd iterations improve median-cut centers without
        // importing a separate quantization implementation.
        for (int iteration = 0; iteration < 3 && centers.size() > 1; iteration++) {
            std::vector<std::array<double, 3>> sums(centers.size(), {0, 0, 0});
            std::vector<uint64_t> weights(centers.size(), 0);
            for (const auto &color : colors) {
                size_t nearest = 0;
                double best = DBL_MAX;
                for (size_t i = 0; i < centers.size(); i++) {
                    double dr = color.r - centers[i][0];
                    double dg = color.g - centers[i][1];
                    double db = color.b - centers[i][2];
                    double distance = 0.30 * dr * dr + 0.59 * dg * dg + 0.11 * db * db;
                    if (distance < best) {
                        best = distance;
                        nearest = i;
                    }
                }
                sums[nearest][0] += color.r * color.count;
                sums[nearest][1] += color.g * color.count;
                sums[nearest][2] += color.b * color.count;
                weights[nearest] += color.count;
            }
            for (size_t i = 0; i < centers.size(); i++) {
                if (!weights[i])
                    continue;
                centers[i] = {sums[i][0] / weights[i], sums[i][1] / weights[i], sums[i][2] / weights[i]};
            }
        }

        for (size_t i = 0; i < centers.size(); i++) {
            palette[i * 3] = (uint8_t)std::clamp(lround(centers[i][0]), 0l, 255l);
            palette[i * 3 + 1] = (uint8_t)std::clamp(lround(centers[i][1]), 0l, 255l);
            palette[i * 3 + 2] = (uint8_t)std::clamp(lround(centers[i][2]), 0l, 255l);
        }
        for (size_t i = centers.size(); i < colorCount; i++) {
            size_t source = i % centers.size();
            memcpy(palette + i * 3, palette + source * 3, 3);
        }
        return result;
    }
};
static float SRGBToLinear(uint8_t value) {
    float c = value / 255.0f;
    return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
}

static uint8_t LinearToSRGB(float value) {
    value = std::clamp(value, 0.0f, 1.0f);
    float c = value <= 0.0031308f ? value * 12.92f : 1.055f * powf(value, 1.0f / 2.4f) - 0.055f;
    return (uint8_t)std::clamp(lroundf(c * 255.0f), 0l, 255l);
}
class Ditherer {
    std::array<std::array<float, 3>, 256> _linearPalette;
    std::array<uint8_t, 64 * 64 * 64> _nearestColor;
    std::array<float, 256> _srgbToLinear;
    std::array<uint8_t, 4097> _linearToSRGB;

  public:
    explicit Ditherer(std::span<const uint8_t> paletteData) {
        const uint8_t *palette = paletteData.data();
        size_t count = std::min<size_t>(256, paletteData.size() / 3);
        for (size_t i = 0; i < _srgbToLinear.size(); i++) {
            _srgbToLinear[i] = SRGBToLinear((uint8_t)i);
        }
        for (size_t i = 0; i < _linearToSRGB.size(); i++) {
            _linearToSRGB[i] = LinearToSRGB((float)i / 4096.0f);
        }
        for (size_t i = 0; i < 256; i++) {
            size_t source = count ? i % count : 0;
            _linearPalette[i] = {SRGBToLinear(palette[source * 3]), SRGBToLinear(palette[source * 3 + 1]),
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
                        if (distance < best) {
                            best = distance;
                            nearest = i;
                        }
                    }
                    _nearestColor[(r << 12) | (g << 6) | b] = (uint8_t)nearest;
                }
            }
        }
    }
    std::vector<uint8_t> indexedPixels(const uint8_t *bytes, size_t width, size_t height,
                                       size_t bytesPerRow) {
        std::vector<uint8_t> result(width * height);
        uint8_t *indices = result.data();
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
                size_t lookup = ((size_t)(sr >> 2) << 12) | ((size_t)(sg >> 2) << 6) | (size_t)(sb >> 2);
                uint8_t paletteIndex = _nearestColor[lookup];
                indices[y * width + x] = paletteIndex;
                std::array<float, 3> error = {std::clamp(r - _linearPalette[paletteIndex][0], -0.25f, 0.25f),
                                              std::clamp(g - _linearPalette[paletteIndex][1], -0.25f, 0.25f),
                                              std::clamp(b - _linearPalette[paletteIndex][2], -0.25f, 0.25f)};
                auto add = [&](std::array<float, 3> &target, float weight) {
                    for (int c = 0; c < 3; c++)
                        target[c] += error[c] * weight;
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
};
} // namespace pnclip::gif_detail
