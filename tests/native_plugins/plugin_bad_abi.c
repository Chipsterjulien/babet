#include "babet/plugin.h"

static babet_status never_called(babet_host_call *call, void *userdata)
{
    (void)call;
    (void)userdata;
    return BABET_STATUS_OK;
}

static const babet_plugin_function_v1 functions[] = {
    {"never", never_called, NULL},
};

static const babet_plugin_descriptor_v1 descriptor = {
    UINT32_C(999),
    (uint32_t)sizeof(babet_plugin_descriptor_v1),
    "bad-abi",
    "1",
    functions,
    1,
};

const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void)
{
    return &descriptor;
}
