#ifndef BABET_PLUGIN_H
#define BABET_PLUGIN_H

#include "babet/babet.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#define BABET_PLUGIN_NOEXCEPT noexcept
extern "C" {
#else
#define BABET_PLUGIN_NOEXCEPT
#endif

/*
 * Experimental native plugin ABI — version 1.
 *
 * Plugins are trusted in-process code. This boundary is C-only: no Lua state,
 * STL/RTTI object, C++ exception or cross-boundary allocator ownership is part
 * of the ABI. A C++ plugin callback must be `noexcept` and contain every C++
 * exception before it returns through this boundary.
 */
#define BABET_PLUGIN_ABI_VERSION_V1 UINT32_C(1)
#define BABET_PLUGIN_QUERY_SYMBOL_V1 "babet_plugin_query_v1"
#define BABET_PLUGIN_MAX_FUNCTIONS_V1 ((size_t)256)
#define BABET_PLUGIN_MAX_FUNCTION_STRUCT_SIZE_V1 UINT32_C(1024)

/*
 * Callback type used only by the native-plugin ABI.
 *
 * In C++ the noexcept specification is part of the function-pointer type, so a
 * potentially-throwing callback cannot be placed in a v1 descriptor without an
 * explicit unsafe cast. This is intentional: the official Babet executable
 * links its GCC/C++ runtimes statically, while an ordinary C++ plugin normally
 * uses the shared runtimes, so Babet cannot provide a reliable cross-DSO C++
 * exception catcher. C plugins see the equivalent plain C function-pointer ABI.
 */
typedef babet_status (*babet_plugin_callback_v1)(babet_host_call *call,
                                                  void *userdata)
    BABET_PLUGIN_NOEXCEPT;

typedef struct babet_plugin_function_v1
{
    /* Length-delimited ASCII identifier; no terminating NUL is required. */
    babet_string_view name;

    /* Scalar callback contract from Lot 10, with noexcept enforced in C++. */
    babet_plugin_callback_v1 function;

    /* Plugin-owned and valid for the process lifetime after a successful load. */
    void *userdata;
} babet_plugin_function_v1;

typedef struct babet_plugin_descriptor_v1
{
    uint32_t abi_version;
    uint32_t struct_size;

    /*
     * Byte stride of each element in functions. It must be at least the v1
     * prefix size. Babet indexes the array by this stride instead of assuming
     * sizeof(babet_plugin_function_v1), allowing a future ABI-compatible tail.
     */
    uint32_t function_struct_size;

    /* Reserved for ABI growth; v1 plugins must set this field to zero. */
    uint32_t reserved;

    /* Length-delimited plugin-owned metadata, copied during loading. */
    babet_string_view name;
    babet_string_view version;

    /* Static plugin-owned declaration array, read only during loading. */
    const babet_plugin_function_v1 *functions;
    size_t function_count;
} babet_plugin_descriptor_v1;

typedef const babet_plugin_descriptor_v1 *
(*babet_plugin_query_v1_function)(void) BABET_PLUGIN_NOEXCEPT;

/* Every v1 plugin exports exactly this symbol with C linkage. */
const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void)
    BABET_PLUGIN_NOEXCEPT;

#ifdef __cplusplus
} /* extern "C" */
#endif

#undef BABET_PLUGIN_NOEXCEPT

#endif /* BABET_PLUGIN_H */
