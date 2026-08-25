#include "babet/plugin.h"

static babet_status never_called(babet_host_call *call, void *userdata)
{
    (void)call;
    (void)userdata;
    return BABET_STATUS_OK;
}

/* Deliberately no terminating NUL. The declared length is rejected before
 * Babet dereferences the four-byte buffer, so ASan must stay quiet. */
static const char raw_name[4] = {'a', 'b', 'c', 'd'};

static const babet_plugin_function_v1 functions[] = {
    {{raw_name, 129}, never_called, NULL},
};

static const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    (uint32_t)sizeof(babet_plugin_descriptor_v1),
    (uint32_t)sizeof(babet_plugin_function_v1),
    0,
    {"bad-name-length", sizeof("bad-name-length") - 1},
    {"1", sizeof("1") - 1},
    functions,
    1,
};

const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void)
{
    return &descriptor;
}
