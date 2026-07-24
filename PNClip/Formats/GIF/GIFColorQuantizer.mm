#import "GIFColorQuantizer.h"
#include <algorithm>
#include <array>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {
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
    if (box.indices.empty()) return;
    box.minR = box.minG = box.minB = 255;
    box.maxR = box.maxG = box.maxB = 0;
    box.population = 0;
    for (size_t index : box.indices) {
        const auto &color = colors[index];
        box.minR = std::min(box.minR, color.r); box.maxR = std::max(box.maxR, color.r);
        box.minG = std::min(box.minG, color.g); box.maxG = std::max(box.maxG, color.g);
        box.minB = std::min(box.minB, color.b); box.maxB = std::max(box.maxB, color.b);
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
}

@implementation GIFColorQuantizer {
    std::array<uint64_t, kHistogramSize> _histogram;
}

- (instancetype)init {
    self = [super init];
    if (self) _histogram.fill(0);
    return self;
}

- (void)addRGBABytes:(const uint8_t *)bytes
               width:(size_t)width
              height:(size_t)height
         bytesPerRow:(size_t)bytesPerRow
          sampleStep:(size_t)sampleStep {
    sampleStep = std::max<size_t>(1, sampleStep);
    for (size_t y = 0; y < height; y += sampleStep) {
        const uint8_t *row = bytes + y * bytesPerRow;
        for (size_t x = 0; x < width; x += sampleStep) {
            const uint8_t *pixel = row + x * 4;
            size_t index = ((size_t)(pixel[0] >> 2) << 12) |
                           ((size_t)(pixel[1] >> 2) << 6) |
                           (size_t)(pixel[2] >> 2);
            _histogram[index]++;
        }
    }
}

- (NSData *)makePaletteWithColorCount:(NSUInteger)requestedCount {
    NSUInteger colorCount = std::max<NSUInteger>(2, std::min<NSUInteger>(256, requestedCount));
    std::vector<ColorEntry> colors;
    colors.reserve(kHistogramSize);
    for (size_t i = 0; i < _histogram.size(); i++) {
        uint64_t count = _histogram[i];
        if (!count) continue;
        colors.push_back({(uint8_t)((((i >> 12) & 63) << 2) | 2),
                          (uint8_t)((((i >> 6) & 63) << 2) | 2),
                          (uint8_t)(((i & 63) << 2) | 2), count});
    }

    NSMutableData *result = [NSMutableData dataWithLength:colorCount * 3];
    uint8_t *palette = (uint8_t *)result.mutableBytes;
    if (colors.empty()) return result;

    ColorBox initial;
    initial.indices.resize(colors.size());
    for (size_t i = 0; i < colors.size(); i++) initial.indices[i] = i;
    UpdateBox(initial, colors);
    std::vector<ColorBox> boxes;
    boxes.push_back(std::move(initial));

    while (boxes.size() < colorCount) {
        auto candidate = boxes.end();
        uint64_t bestScore = 0;
        for (auto it = boxes.begin(); it != boxes.end(); ++it) {
            if (it->indices.size() < 2) continue;
            uint64_t range = std::max({it->maxR - it->minR,
                                       it->maxG - it->minG,
                                       it->maxB - it->minB});
            uint64_t score = range * it->population;
            if (score > bestScore) { bestScore = score; candidate = it; }
        }
        if (candidate == boxes.end()) break;

        int channel = WidestChannel(*candidate);
        std::sort(candidate->indices.begin(), candidate->indices.end(),
                  [&](size_t a, size_t b) {
                      return ColorComponent(colors[a], channel) < ColorComponent(colors[b], channel);
                  });
        uint64_t half = candidate->population / 2;
        uint64_t accumulated = 0;
        size_t split = 1;
        for (; split < candidate->indices.size(); split++) {
            accumulated += colors[candidate->indices[split - 1]].count;
            if (accumulated >= half) break;
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
            r += color.r * color.count; g += color.g * color.count; b += color.b * color.count;
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
                if (distance < best) { best = distance; nearest = i; }
            }
            sums[nearest][0] += color.r * color.count;
            sums[nearest][1] += color.g * color.count;
            sums[nearest][2] += color.b * color.count;
            weights[nearest] += color.count;
        }
        for (size_t i = 0; i < centers.size(); i++) {
            if (!weights[i]) continue;
            centers[i] = {sums[i][0] / weights[i], sums[i][1] / weights[i],
                          sums[i][2] / weights[i]};
        }
    }

    for (size_t i = 0; i < centers.size(); i++) {
        palette[i * 3] = (uint8_t)std::clamp(lround(centers[i][0]), 0l, 255l);
        palette[i * 3 + 1] = (uint8_t)std::clamp(lround(centers[i][1]), 0l, 255l);
        palette[i * 3 + 2] = (uint8_t)std::clamp(lround(centers[i][2]), 0l, 255l);
    }
    for (NSUInteger i = centers.size(); i < colorCount; i++) {
        NSUInteger source = i % centers.size();
        memcpy(palette + i * 3, palette + source * 3, 3);
    }
    return result;
}
@end
