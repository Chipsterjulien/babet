#ifndef BABET_NATIVE_PLUGIN_HPP
#define BABET_NATIVE_PLUGIN_HPP

#include "babet/babet.h"

#include <memory>
#include <string>
#include <vector>

struct lua_State;
struct babet_host_call;

struct NativePluginFunctionRegistration;

class NativePluginRuntime
{
public:
    explicit NativePluginRuntime(lua_State *state) noexcept;
    ~NativePluginRuntime();

    NativePluginRuntime(const NativePluginRuntime &) = delete;
    NativePluginRuntime &operator=(const NativePluginRuntime &) = delete;

public:
    lua_State *state_ = nullptr;
    std::vector<std::unique_ptr<NativePluginFunctionRegistration>> functions_;
    std::vector<babet_value> arguments_;
    std::string result_string_storage_;
    std::string callback_error_storage_;
    const char *callback_fallback_error_ = nullptr;
    babet_host_call *active_call_ = nullptr;
    bool callback_active_ = false;
    std::vector<std::string> loaded_paths_;
    std::vector<void *> loaded_handles_;

    friend int lua_native_plugin_load(lua_State *state);
    friend int native_plugin_function_thunk(lua_State *state) noexcept;
    friend bool native_plugin_call_is_active(const babet_host_call *call) noexcept;
    friend babet_status native_plugin_copy_result(
        babet_host_call *call, const babet_value *value) noexcept;
    friend babet_status native_plugin_copy_error(
        babet_host_call *call, const char *message) noexcept;
};

enum class NativePluginMode
{
    allowed,
    generated_application,
    embedding,
    worker,
};

/* Registers babet.plugin.load. The runtime pointer is required only in allowed mode. */
void register_native_plugin(lua_State *state, NativePluginRuntime *runtime,
                            NativePluginMode mode);

#endif // BABET_NATIVE_PLUGIN_HPP
