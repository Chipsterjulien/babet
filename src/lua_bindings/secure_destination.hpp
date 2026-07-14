#pragma once

#include <filesystem>
#include <optional>
#include <string>

class SecureDestination
{
public:
    SecureDestination() = default;
    ~SecureDestination();

    SecureDestination(const SecureDestination &) = delete;
    SecureDestination &operator=(const SecureDestination &) = delete;

    SecureDestination(SecureDestination &&other) noexcept;
    SecureDestination &operator=(SecureDestination &&other) noexcept;

    std::optional<std::string> open_root(const std::filesystem::path &root);

    std::optional<std::string>
    ensure_directory(const std::filesystem::path &relative_path);

    std::optional<std::string>
    copy_regular_file(const std::filesystem::path &source,
                      const std::filesystem::path &relative_destination);

    std::optional<std::string>
    move_entry(const std::filesystem::path &source,
               const std::filesystem::path &relative_destination);

    std::optional<std::string>
    create_symlink(const std::filesystem::path &target,
                   const std::filesystem::path &relative_destination);

    void remove_entry_best_effort(
        const std::filesystem::path &relative_destination) noexcept;

private:
    int root_fd_ = -1;
    std::filesystem::path root_path_;

    std::optional<std::string>
    open_parent(const std::filesystem::path &relative_path,
                int &parent_fd, std::string &leaf,
                bool create_parents) const;

    std::optional<std::string>
    validate_relative(const std::filesystem::path &relative_path) const;
};
