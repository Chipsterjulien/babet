#include "babet/plugin.h"

#include <exception>
#include <new>
#include <stdexcept>
#include <string>

extern "C" {
static babet_status decorate_callback(babet_host_call *call,
                                      void *userdata) noexcept
{
    (void)userdata;
    try
    {
        if (babet_host_call_argument_count(call) != 1)
            return BABET_STATUS_INVALID_ARGUMENT;
        const babet_value *arguments = babet_host_call_arguments(call);
        if (!arguments || arguments[0].type != BABET_VALUE_STRING)
            return BABET_STATUS_INVALID_ARGUMENT;

        std::string value("cpp:");
        value.append(arguments[0].as.string.data, arguments[0].as.string.length);
        babet_value result{};
        result.type = BABET_VALUE_STRING;
        result.as.string.data = value.data();
        result.as.string.length = value.size();
        return babet_host_call_set_result(call, &result);
    }
    catch (const std::bad_alloc &)
    {
        (void)babet_host_call_set_error(call, "C++ fixture out of memory");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (const std::exception &error)
    {
        (void)babet_host_call_set_error(call, error.what());
        return BABET_STATUS_INTERNAL_ERROR;
    }
    catch (...)
    {
        (void)babet_host_call_set_error(call, "unknown C++ fixture exception");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

static babet_status caught_exception_callback(babet_host_call *call,
                                              void *userdata) noexcept
{
    (void)userdata;
    try
    {
        throw std::runtime_error("caught C++ plugin exception sentinel");
    }
    catch (const std::exception &error)
    {
        (void)babet_host_call_set_error(call, error.what());
        return BABET_STATUS_INTERNAL_ERROR;
    }
    catch (...)
    {
        (void)babet_host_call_set_error(call, "unknown C++ plugin exception");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}
} // extern "C"

namespace
{
const babet_plugin_function_v1 functions[] = {
    {{"decorate", sizeof("decorate") - 1}, decorate_callback, nullptr},
    {{"caught_exception", sizeof("caught_exception") - 1},
     caught_exception_callback, nullptr},
};

const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    static_cast<uint32_t>(sizeof(babet_plugin_descriptor_v1)),
    static_cast<uint32_t>(sizeof(babet_plugin_function_v1)),
    0,
    {"lot11-cpp-fixture", sizeof("lot11-cpp-fixture") - 1},
    {"1.0.0", sizeof("1.0.0") - 1},
    functions,
    sizeof(functions) / sizeof(functions[0]),
};
} // namespace

extern "C" const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void) noexcept
{
    return &descriptor;
}
