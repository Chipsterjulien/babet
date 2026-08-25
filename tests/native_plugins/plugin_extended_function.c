#include "babet/plugin.h"

#include <stdint.h>

static babet_status answer_callback(babet_host_call *call, void *userdata)
{
    (void)userdata;
    babet_value result = {0};
    result.type = BABET_VALUE_INTEGER;
    result.as.integer = 42;
    return babet_host_call_set_result(call, &result);
}

typedef struct extended_function
{
    babet_plugin_function_v1 v1;
    uint64_t future_tail;
} extended_function;

static const char answer_name[6] = {'a', 'n', 's', 'w', 'e', 'r'};

static const extended_function functions[] = {
    {{{answer_name, sizeof(answer_name)}, answer_callback, NULL},
     UINT64_C(0x1122334455667788)},
};

static const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    (uint32_t)sizeof(babet_plugin_descriptor_v1),
    (uint32_t)sizeof(extended_function),
    0,
    {"extended-function", sizeof("extended-function") - 1},
    {"1", sizeof("1") - 1},
    (const babet_plugin_function_v1 *)functions,
    1,
};

const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void)
{
    return &descriptor;
}
