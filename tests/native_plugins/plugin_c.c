#include "babet/plugin.h"

#include <stddef.h>
#include <string.h>

static babet_status echo_callback(babet_host_call *call, void *userdata)
{
    (void)userdata;
    if (babet_host_call_argument_count(call) != 1)
        return BABET_STATUS_INVALID_ARGUMENT;

    const babet_value *arguments = babet_host_call_arguments(call);
    if (!arguments || arguments[0].type != BABET_VALUE_STRING)
        return BABET_STATUS_INVALID_ARGUMENT;

    const char prefix[] = {'C', ':', '\0'};
    char output[128];
    if (arguments[0].as.string.length > sizeof(output) - 2)
    {
        (void)babet_host_call_set_error(call, "fixture input too large");
        return BABET_STATUS_INVALID_ARGUMENT;
    }

    memcpy(output, prefix, 2);
    memcpy(output + 2, arguments[0].as.string.data,
           arguments[0].as.string.length);
    babet_value result = {0};
    result.type = BABET_VALUE_STRING;
    result.as.string.data = output;
    result.as.string.length = arguments[0].as.string.length + 2;
    return babet_host_call_set_result(call, &result);
}

static babet_status add_callback(babet_host_call *call, void *userdata)
{
    (void)userdata;
    if (babet_host_call_argument_count(call) != 2)
        return BABET_STATUS_INVALID_ARGUMENT;
    const babet_value *arguments = babet_host_call_arguments(call);
    if (!arguments || arguments[0].type != BABET_VALUE_INTEGER ||
        arguments[1].type != BABET_VALUE_INTEGER)
        return BABET_STATUS_INVALID_ARGUMENT;

    babet_value result = {0};
    result.type = BABET_VALUE_INTEGER;
    result.as.integer = arguments[0].as.integer + arguments[1].as.integer;
    return babet_host_call_set_result(call, &result);
}


static babet_status version_callback(babet_host_call *call, void *userdata)
{
    (void)userdata;
    if (babet_host_call_argument_count(call) != 0)
        return BABET_STATUS_INVALID_ARGUMENT;

    const char *version = babet_version();
    babet_value result = {0};
    result.type = BABET_VALUE_STRING;
    result.as.string.data = version;
    result.as.string.length = strlen(version);
    return babet_host_call_set_result(call, &result);
}

static babet_status status_name_callback(babet_host_call *call, void *userdata)
{
    (void)userdata;
    if (babet_host_call_argument_count(call) != 0)
        return BABET_STATUS_INVALID_ARGUMENT;

    const char *name = babet_status_name(BABET_STATUS_OK);
    babet_value result = {0};
    result.type = BABET_VALUE_STRING;
    result.as.string.data = name;
    result.as.string.length = strlen(name);
    return babet_host_call_set_result(call, &result);
}

static const babet_plugin_function_v1 functions[] = {
    {"echo", echo_callback, NULL},
    {"add", add_callback, NULL},
    {"version", version_callback, NULL},
    {"status_name", status_name_callback, NULL},
};

static const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    (uint32_t)sizeof(babet_plugin_descriptor_v1),
    "lot11-c-fixture",
    "1.0.0",
    functions,
    sizeof(functions) / sizeof(functions[0]),
};

const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void)
{
    return &descriptor;
}
