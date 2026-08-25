#ifndef BABET_HOST_CALL_INTERNAL_HPP
#define BABET_HOST_CALL_INTERNAL_HPP

#include "babet/babet.h"

struct babet_host_call
{
    const babet_value *arguments = nullptr;
    size_t argument_count = 0;
    babet_value result{};
    babet_status setter_status = BABET_STATUS_OK;

    void *owner = nullptr;
    bool (*is_active)(const babet_host_call *call) noexcept = nullptr;
    babet_status (*copy_result)(babet_host_call *call,
                                const babet_value *value) noexcept = nullptr;
    babet_status (*copy_error)(babet_host_call *call,
                               const char *message) noexcept = nullptr;
};

#endif // BABET_HOST_CALL_INTERNAL_HPP
