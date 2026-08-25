#include "babet/plugin.h"

static babet_status never_called(babet_host_call *call, void *userdata)
{
    (void)call;
    (void)userdata;
    return BABET_STATUS_OK;
}

static const babet_plugin_function_v1 functions[] = {
    {{"never", sizeof("never") - 1}, never_called, NULL},
};

static const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    (uint32_t)sizeof(babet_plugin_descriptor_v1),
    (uint32_t)sizeof(babet_plugin_function_v1),
    UINT32_C(1),
    {"reserved-nonzero", sizeof("reserved-nonzero") - 1},
    {"1", sizeof("1") - 1},
    functions,
    1,
};

const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void)
{
    return &descriptor;
}
