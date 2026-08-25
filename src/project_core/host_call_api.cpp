#include "host_call_internal.hpp"

namespace
{
bool valid_value_type(babet_value_type type) noexcept
{
    switch (type)
    {
    case BABET_VALUE_NIL:
    case BABET_VALUE_BOOLEAN:
    case BABET_VALUE_INTEGER:
    case BABET_VALUE_NUMBER:
    case BABET_VALUE_STRING:
        return true;
    }
    return false;
}

bool active_call(const babet_host_call *call) noexcept
{
    return call && call->is_active && call->is_active(call);
}
} // namespace

extern "C" size_t babet_host_call_argument_count(const babet_host_call *call)
{
    return active_call(call) ? call->argument_count : 0;
}

extern "C" const babet_value *
babet_host_call_arguments(const babet_host_call *call)
{
    return active_call(call) ? call->arguments : nullptr;
}

extern "C" babet_status babet_host_call_set_result(
    babet_host_call *call, const babet_value *value)
{
    if (!active_call(call) || !value || !call->copy_result ||
        !valid_value_type(value->type) ||
        (value->type == BABET_VALUE_STRING && !value->as.string.data &&
         value->as.string.length != 0))
        return BABET_STATUS_INVALID_ARGUMENT;

    return call->copy_result(call, value);
}

extern "C" babet_status babet_host_call_set_error(
    babet_host_call *call, const char *message)
{
    if (!active_call(call) || !message || !call->copy_error)
        return BABET_STATUS_INVALID_ARGUMENT;

    return call->copy_error(call, message);
}
