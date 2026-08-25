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
 * of the ABI. A C++ plugin must keep every exported function `noexcept`.
 */
#define BABET_PLUGIN_ABI_VERSION_V1 UINT32_C(1)
#define BABET_PLUGIN_QUERY_SYMBOL_V1 "babet_plugin_query_v1"
#define BABET_PLUGIN_MAX_FUNCTIONS_V1 ((size_t)256)

typedef struct babet_plugin_function_v1
{
    /* Copied by Babet while the descriptor is queried. */
    const char *name;

    /* Same scalar callback contract as Lot 10 host functions. */
    babet_host_function function;

    /* Plugin-owned and valid for the process lifetime after a successful load. */
    void *userdata;
} babet_plugin_function_v1;

typedef struct babet_plugin_descriptor_v1
{
    uint32_t abi_version;
    uint32_t struct_size;

    /* Static plugin-owned strings. Babet copies them during loading. */
    const char *name;
    const char *version;

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
