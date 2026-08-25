#ifndef BABET_EMBEDDING_H
#define BABET_EMBEDDING_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Experimental embedding API.
 *
 * Lots 6–11 intentionally exercise this small C surface before treating it as a
 * frozen ABI.  The public header exposes no Lua or C++ type.
 */
typedef struct babet_context babet_context;
typedef struct babet_host_call babet_host_call;

typedef enum babet_status
{
    BABET_STATUS_OK = 0,
    BABET_STATUS_INVALID_ARGUMENT = 1,
    BABET_STATUS_BUSY = 2,
    BABET_STATUS_WRONG_THREAD = 3,
    BABET_STATUS_LUA_ERROR = 4,
    BABET_STATUS_OUT_OF_MEMORY = 5,
    BABET_STATUS_INTERNAL_ERROR = 6,
    BABET_STATUS_UNSUPPORTED_VALUE = 7,
    BABET_STATUS_REENTRANT_CALL = 8
} babet_status;

typedef enum babet_value_type
{
    BABET_VALUE_NIL = 0,
    BABET_VALUE_BOOLEAN = 1,
    BABET_VALUE_INTEGER = 2,
    BABET_VALUE_NUMBER = 3,
    BABET_VALUE_STRING = 4
} babet_value_type;

typedef struct babet_string_view
{
    const char *data;
    size_t length;
} babet_string_view;

typedef struct babet_value
{
    babet_value_type type;
    union
    {
        int boolean;
        int64_t integer;
        double number;
        babet_string_view string;
    } as;
} babet_value;

/*
 * Scalar callback type for embedding host functions. An embedding registration
 * is invoked synchronously when Lua calls babet.host.<name>(...). The native
 * plugin ABI reuses babet_host_call and the same scalar helpers, but declares a
 * distinct babet_plugin_callback_v1 type in plugin.h so C++ plugins can enforce
 * noexcept at compile time.
 *
 * Embedding callbacks run on the context owner thread, including when Lua calls
 * them from a coroutine belonging to that same global Lua state. They must not
 * re-enter the babet_context_* API while active; such calls are rejected with
 * BABET_STATUS_REENTRANT_CALL. Arguments are borrowed and valid only for the
 * callback duration. Use babet_host_call_set_result() to publish a scalar
 * result; omitting a result yields Lua nil.
 *
 * Return BABET_STATUS_OK on success. Any other status is converted into a Lua
 * error. babet_host_call_set_error() may be used first to attach a copied
 * diagnostic. Because embedding callbacks live in the host program's own C++
 * runtime, Babet contains accidentally thrown C++ exceptions before control
 * returns to Lua. This exception guarantee does not apply to separately loaded
 * native plugins; plugin.h enforces their separate noexcept callback contract.
 */
typedef babet_status (*babet_host_function)(babet_host_call *call,
                                            void *userdata);

/* Returns the Babet semantic version compiled into the library. */
const char *babet_version(void);

/* Stable symbolic name for a babet_status value. */
const char *babet_status_name(babet_status status);

/*
 * Creates the single active embedded runtime for this process.
 *
 * The returned context must be used and destroyed from the same host thread.
 * A second simultaneous context is rejected with BABET_STATUS_BUSY.
 */
babet_status babet_context_create(babet_context **out_context);

/*
 * Configures one explicit on-disk Lua module root for this context.
 *
 * The root is prepended to package.path with the same ?.lua and ?/init.lua
 * semantics as Babet folder mode, and is propagated to workers created from
 * this embedded runtime. The path is resolved to an absolute path when this
 * function is called.
 *
 * This first API permits exactly one search-root configuration and it must be
 * done before the first Lua execution call (`babet_context_run()` or
 * `babet_context_call_global()`). This avoids racing the process-wide worker
 * initialization context. Missing paths and non-directory
 * paths return BABET_STATUS_INVALID_ARGUMENT.
 */
babet_status babet_context_set_search_root(babet_context *context,
                                            const char *search_root);

/*
 * Executes one text Lua chunk in the context.
 *
 * chunk_name may be NULL; when non-NULL it is used in Lua diagnostics.
 * Chunk results are intentionally discarded. The first scalar host/Lua value
 * exchange is provided separately through set_global/get_global and call_global,
 * keeping chunk execution stack-neutral and the public boundary independent from
 * Lua internals.
 */
babet_status babet_context_run(babet_context *context,
                               const char *chunk,
                               size_t chunk_length,
                               const char *chunk_name);

/*
 * Stores one scalar host value in the embedded Lua global table.
 *
 * Supported values are nil, boolean, signed 64-bit integer, double and byte
 * string. A string may contain embedded NUL bytes because its length is
 * explicit. This first value slice affects only the main embedded Lua state;
 * worker states remain isolated and use their existing worker arguments/results.
 */
babet_status babet_context_set_global(babet_context *context,
                                       const char *name,
                                       const babet_value *value);

/*
 * Reads one scalar value from the embedded Lua global table.
 *
 * Tables, functions, userdata and threads return
 * BABET_STATUS_UNSUPPORTED_VALUE. For BABET_VALUE_STRING, the returned data
 * pointer is owned by the context and stays valid until the next mutating
 * context call or destruction. On success booleans are normalized to 0 or 1.
 */
babet_status babet_context_get_global(babet_context *context,
                                       const char *name,
                                       babet_value *out_value);

/*
 * Calls one Lua function stored directly in the main global table.
 *
 * Arguments use the same scalar babet_value contract as set_global(). Exactly
 * one Lua result is requested: a function returning no values yields nil, while
 * extra Lua results are discarded. The result uses the same scalar contract and
 * borrowed-string lifetime as get_global(). Structured results return
 * BABET_STATUS_UNSUPPORTED_VALUE. Function lookup/call errors return
 * BABET_STATUS_LUA_ERROR with context-owned diagnostics.
 */
babet_status babet_context_call_global(babet_context *context,
                                        const char *function_name,
                                        const babet_value *arguments,
                                        size_t argument_count,
                                        babet_value *out_result);

/*
 * Registers one scalar host function as babet.host.<name>.
 *
 * name is copied by Babet and must be a simple ASCII Lua identifier that is not
 * a Lua reserved keyword. Duplicate names are rejected. userdata is borrowed
 * and must remain valid until the context is destroyed; this first API
 * intentionally has no unregister path.
 * Host functions are installed only in the main embedded Lua state, not in
 * worker states. Registration may happen between Lua execution calls but never
 * from inside another host callback.
 */
babet_status babet_context_register_host_function(
    babet_context *context,
    const char *name,
    babet_host_function function,
    void *userdata);

/* Borrowed scalar arguments for the currently active host callback. */
size_t babet_host_call_argument_count(const babet_host_call *call);
const babet_value *babet_host_call_arguments(const babet_host_call *call);

/*
 * Copies one scalar callback result into Babet-owned storage immediately.
 * Strings are therefore safe even when the source view points at temporary
 * host storage. The last successful setter call wins.
 */
babet_status babet_host_call_set_result(babet_host_call *call,
                                         const babet_value *value);

/*
 * Copies a human-readable diagnostic for a non-OK callback return status.
 * Calling this does not itself fail the callback; the callback still returns
 * the desired non-OK babet_status.
 */
babet_status babet_host_call_set_error(babet_host_call *call,
                                        const char *message);

/*
 * Returns the last detailed diagnostic owned by the context, or an empty
 * string when no diagnostic is pending.  The pointer stays valid until the
 * next call mutating that context or until destruction.
 */
const char *babet_context_last_error(const babet_context *context);

/*
 * Destroys a context and performs the same terminal-aware Lua cleanup as the
 * Babet CLI.  NULL is accepted.  A live context must be destroyed by its
 * owner thread.
 */
babet_status babet_context_destroy(babet_context *context);

#ifdef __cplusplus
}
#endif

#endif /* BABET_EMBEDDING_H */
