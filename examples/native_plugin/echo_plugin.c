#include "babet/plugin.h"

static babet_status echo(babet_host_call *call, void *userdata)
{
    (void)userdata;
    const babet_value *arguments = babet_host_call_arguments(call);
    if (babet_host_call_argument_count(call) != 1 || !arguments ||
        arguments[0].type != BABET_VALUE_STRING)
    {
        (void)babet_host_call_set_error(call, "echo expects one string");
        return BABET_STATUS_INVALID_ARGUMENT;
    }
    return babet_host_call_set_result(call, &arguments[0]);
}

static const babet_plugin_function_v1 functions[] = {
    {{"echo", sizeof("echo") - 1}, echo, 0},
};

static const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    (uint32_t)sizeof(babet_plugin_descriptor_v1),
    (uint32_t)sizeof(babet_plugin_function_v1),
    0,
    {"example-c", sizeof("example-c") - 1},
    {"1.0.0", sizeof("1.0.0") - 1},
    functions,
    1,
};

const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void)
{
    return &descriptor;
}
