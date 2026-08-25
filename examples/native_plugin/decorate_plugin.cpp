#include "babet/plugin.h"

#include <string>

namespace
{
babet_status decorate(babet_host_call *call, void *userdata)
{
    (void)userdata;
    const babet_value *arguments = babet_host_call_arguments(call);
    if (babet_host_call_argument_count(call) != 1 || !arguments ||
        arguments[0].type != BABET_VALUE_STRING)
        return BABET_STATUS_INVALID_ARGUMENT;

    std::string value("C++: ");
    value.append(arguments[0].as.string.data, arguments[0].as.string.length);
    babet_value result{};
    result.type = BABET_VALUE_STRING;
    result.as.string.data = value.data();
    result.as.string.length = value.size();
    return babet_host_call_set_result(call, &result);
}

const babet_plugin_function_v1 functions[] = {
    {"decorate", decorate, nullptr},
};

const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    static_cast<uint32_t>(sizeof(babet_plugin_descriptor_v1)),
    "example-cpp",
    "1.0.0",
    functions,
    1,
};
} // namespace

extern "C" const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void) noexcept
{
    return &descriptor;
}
