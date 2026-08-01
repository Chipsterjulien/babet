#!/bin/bash
# Test unitaire hermétique du décodeur de bornes des événements inotify.
# Aucun des buffers malformés ci-dessous ne peut normalement provenir du
# noyau ; ils valident la défense en profondeur avant que strnlen() ou les
# champs variables ne soient consultés.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

cat > "${TMPDIR_TEST}/test.cpp" <<'CPP'
#include "lua_bindings/inotify_buffer.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>

using babet::inotify_detail::RecordStatus;
using babet::inotify_detail::RecordView;
using babet::inotify_detail::next_record;

namespace
{
    int passes = 0;
    int failures = 0;

    void check(const char *name, bool condition)
    {
        if (condition)
        {
            std::cout << "[PASS] " << name << '\n';
            ++passes;
        }
        else
        {
            std::cout << "[FAIL] " << name << '\n';
            ++failures;
        }
    }

    template <std::size_t N>
    void write_header(std::array<std::byte, N> &buffer,
                      std::size_t offset,
                      std::uint32_t len,
                      std::int32_t wd = 7,
                      std::uint32_t mask = IN_CREATE,
                      std::uint32_t cookie = 9)
    {
        struct inotify_event event{};
        event.wd = wd;
        event.mask = mask;
        event.cookie = cookie;
        event.len = len;
        std::memcpy(buffer.data() + offset, &event, sizeof(event));
    }
}

int main()
{
    RecordView view;
    const char dummy = '\0';

    check("empty buffer terminates normally",
          next_record(&dummy, 0, 0, view) == RecordStatus::end);
    check("offset beyond the buffer is rejected",
          next_record(&dummy, 0, 1, view) ==
              RecordStatus::truncated_header);

    std::array<std::byte, sizeof(struct inotify_event) - 1> short_header{};
    check("truncated fixed header is rejected",
          next_record(reinterpret_cast<const char *>(short_header.data()),
                      short_header.size(), 0, view) ==
              RecordStatus::truncated_header);

    std::array<std::byte, sizeof(struct inotify_event)> no_name{};
    write_header(no_name, 0, 0);
    check("exact zero-name event is accepted",
          next_record(reinterpret_cast<const char *>(no_name.data()),
                      no_name.size(), 0, view) == RecordStatus::record &&
              view.record_size == sizeof(struct inotify_event) &&
              view.wd == 7 && view.mask == IN_CREATE &&
              view.cookie == 9);

    constexpr std::size_t named_size = sizeof(struct inotify_event) + 4;
    std::array<std::byte, named_size> named{};
    write_header(named, 0, 4);
    const char name[4] = {'a', '\0', '\0', '\0'};
    std::memcpy(named.data() + sizeof(struct inotify_event), name, 4);
    check("exact named event is accepted",
          next_record(reinterpret_cast<const char *>(named.data()),
                      named.size(), 0, view) == RecordStatus::record &&
              view.record_size == named_size &&
              std::memcmp(view.name, name, 4) == 0);

    std::array<std::byte, named_size> short_name{};
    write_header(short_name, 0, 8);
    check("declared name beyond the read buffer is rejected",
          next_record(reinterpret_cast<const char *>(short_name.data()),
                      short_name.size(), 0, view) ==
              RecordStatus::truncated_name);

    std::array<std::byte, named_size> huge_name{};
    write_header(huge_name, 0, std::numeric_limits<std::uint32_t>::max());
    check("huge declared name cannot overflow the bounds check",
          next_record(reinterpret_cast<const char *>(huge_name.data()),
                      huge_name.size(), 0, view) ==
              RecordStatus::truncated_name);

    constexpr std::size_t first_size = sizeof(struct inotify_event);
    constexpr std::size_t second_size = sizeof(struct inotify_event) + 4;
    std::array<std::byte, first_size + second_size> two{};
    write_header(two, 0, 0, 1, IN_CREATE, 0);
    write_header(two, first_size, 4, 2, IN_DELETE, 3);
    std::memcpy(two.data() + first_size + sizeof(struct inotify_event),
                name, 4);
    const auto first_status = next_record(
        reinterpret_cast<const char *>(two.data()), two.size(), 0, view);
    const std::size_t next_offset = view.record_size;
    const auto second_status = next_record(
        reinterpret_cast<const char *>(two.data()), two.size(), next_offset,
        view);
    const std::size_t end_offset = next_offset + view.record_size;
    check("multiple records advance by their validated sizes",
          first_status == RecordStatus::record &&
              second_status == RecordStatus::record &&
              view.wd == 2 && view.mask == IN_DELETE &&
              end_offset == two.size() &&
              next_record(reinterpret_cast<const char *>(two.data()),
                          two.size(), end_offset, view) == RecordStatus::end);

    std::cout << "inotify buffer regression tests: " << passes
              << " PASS / " << failures << " FAIL\n";
    return failures == 0 ? 0 : 1;
}
CPP

"${CXX:-c++}" -std=c++23 -Wall -Wextra -Wpedantic -Werror \
    -I"${PROJECT_DIR}/src" "${TMPDIR_TEST}/test.cpp" \
    -o "${TMPDIR_TEST}/test_inotify_buffer"
"${TMPDIR_TEST}/test_inotify_buffer"
