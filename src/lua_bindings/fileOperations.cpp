#include "fileOperations.hpp"
#include <filesystem>
#include <optional>
#include <string>
#include <system_error>

/**
 * @brief Copies a file from source to destination.
 *
 * @param source The source file path.
 * @param destination The destination file path.
 * @return std::optional<std::string> An optional string containing an error message if any, or an empty optional if successful.
 */
std::optional<std::string> custom_copy_file(const std::filesystem::path& source, const std::filesystem::path& destination) {
    std::error_code ec;

    // Check if source file exists, without confusing an inspection
    // failure (EACCES/EIO/...) with a genuinely missing path.
    const bool source_exists = std::filesystem::exists(source, ec);
    if (ec) {
        return "cannot inspect source file '" + source.string() + "': " +
               ec.message();
    }
    if (!source_exists) {
        return "Source file does not exist: " + source.string();
    }

    // Check if destination path is a directory. status(path, ec) reports
    // ENOENT for a destination that does not exist yet, which is a normal
    // copy_file use case and must not be treated as an inspection failure.
    ec.clear();
    const std::filesystem::file_status destination_status =
        std::filesystem::status(destination, ec);
    if (ec && ec != std::errc::no_such_file_or_directory &&
        ec != std::errc::not_a_directory) {
        return "cannot inspect destination path '" + destination.string() +
               "': " + ec.message();
    }
    if (!ec && std::filesystem::is_directory(destination_status)) {
        return "Destination path is a directory: " + destination.string();
    }

    // Copy the file
    std::filesystem::copy_file(source, destination, std::filesystem::copy_options::overwrite_existing, ec);
    if (ec) {
        return "cannot copy file: " + ec.message();
    }

    return std::nullopt;
}
