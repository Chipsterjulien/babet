#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

#include <sys/inotify.h>

namespace babet::inotify_detail
{

    enum class RecordStatus
    {
        record,
        end,
        truncated_header,
        truncated_name,
    };

    struct RecordView
    {
        std::int32_t wd = 0;
        std::uint32_t mask = 0;
        std::uint32_t cookie = 0;
        std::uint32_t len = 0;
        const char *name = nullptr;
        std::size_t record_size = 0;
    };

    // Décode uniquement les bornes structurelles d'un enregistrement inotify.
    // L'en-tête est copié avec memcpy afin de ne jamais dépendre de l'alignement
    // du buffer fourni. `name` reste une vue dans le buffer d'origine.
    inline RecordStatus next_record(const char *buffer,
                                    std::size_t buffer_size,
                                    std::size_t offset,
                                    RecordView &out) noexcept
    {
        out = RecordView{};

        if (offset == buffer_size)
        {
            return RecordStatus::end;
        }
        if (offset > buffer_size)
        {
            return RecordStatus::truncated_header;
        }

        const std::size_t remaining = buffer_size - offset;
        if (remaining < sizeof(struct inotify_event))
        {
            return RecordStatus::truncated_header;
        }

        struct inotify_event event{};
        std::memcpy(&event, buffer + offset, sizeof(event));
        out.wd = event.wd;
        out.mask = event.mask;
        out.cookie = event.cookie;
        out.len = event.len;

        const std::size_t name_capacity =
            remaining - sizeof(struct inotify_event);
        if (static_cast<std::size_t>(out.len) > name_capacity)
        {
            return RecordStatus::truncated_name;
        }

        out.name = buffer + offset + sizeof(struct inotify_event);
        out.record_size = sizeof(struct inotify_event) +
                          static_cast<std::size_t>(out.len);
        return RecordStatus::record;
    }

} // namespace babet::inotify_detail
