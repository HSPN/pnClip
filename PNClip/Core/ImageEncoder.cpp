#include "ImageEncoder.hpp"

#include <fstream>

namespace pnclip {

bool writeFileAtomically(const std::filesystem::path& destination,
                         std::span<const std::byte> data,
                         EncodingError& error) {
    auto temporary = destination;
    temporary += ".tmp";
    {
        std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
        if (!stream || !stream.write(reinterpret_cast<const char*>(data.data()),
                                     static_cast<std::streamsize>(data.size()))) {
            error = {1, "Could not write encoded image"};
            std::error_code ignored;
            std::filesystem::remove(temporary, ignored);
            return false;
        }
    }
    std::error_code ec;
    std::filesystem::rename(temporary, destination, ec);
    if (ec) {
        std::filesystem::remove(destination, ec);
        ec.clear();
        std::filesystem::rename(temporary, destination, ec);
    }
    if (ec) {
        error = {2, ec.message()};
        return false;
    }
    return true;
}

}  // namespace pnclip
