#include <FL/Fl.H>
#include <FL/Fl_Button.H>
#include <FL/Fl_Window.H>

#include <babet/babet.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <limits>
#include <string>
#include <string_view>

namespace {

constexpr std::string_view kBootstrapLua = R"lua(
function on_counter_click(attempt)
    if attempt == 2 then
        error("intentional Lot 9 callback failure")
    end
    babet.host.set_button_label(("Lua counter: %d"):format(attempt))
    return attempt
end
)lua";

struct HostState {
    babet_context *ctx = nullptr;
    Fl_Window *window = nullptr;
    Fl_Button *button = nullptr;
    bool callbacks_enabled = false;
    bool self_test = false;
    bool self_test_failed = false;
    unsigned self_test_step = 0;
    std::uint64_t attempts = 0;
    std::uint64_t successful_calls = 0;
    std::uint64_t lua_errors = 0;
    std::uint64_t host_label_updates = 0;
    std::int64_t last_value = 0;
};

babet_status set_button_label_host(babet_host_call *call, void *userdata)
{
    auto *state = static_cast<HostState *>(userdata);
    const size_t count = babet_host_call_argument_count(call);
    const babet_value *arguments = babet_host_call_arguments(call);
    if (state == nullptr || !state->callbacks_enabled || state->button == nullptr) {
        (void)babet_host_call_set_error(call, "GUI is not available");
        return BABET_STATUS_INTERNAL_ERROR;
    }
    if (count != 1 || arguments == nullptr ||
        arguments[0].type != BABET_VALUE_STRING) {
        (void)babet_host_call_set_error(
            call, "set_button_label expects exactly one string argument");
        return BABET_STATUS_INVALID_ARGUMENT;
    }
    if (std::memchr(arguments[0].as.string.data, '\0',
                    arguments[0].as.string.length) != nullptr) {
        (void)babet_host_call_set_error(
            call, "set_button_label does not accept embedded NUL bytes");
        return BABET_STATUS_INVALID_ARGUMENT;
    }

    const std::string label(arguments[0].as.string.data,
                            arguments[0].as.string.length);
    state->button->copy_label(label.c_str());
    ++state->host_label_updates;
    return BABET_STATUS_OK;
}

void log_lua_failure(HostState &state, babet_status status) noexcept
{
    ++state.lua_errors;
    const char *detail = state.ctx ? babet_context_last_error(state.ctx) : "";
    std::fprintf(stderr,
                 "[babet-fltk-prototype] Lua callback error (%s): %s\n",
                 babet_status_name(status), detail ? detail : "");
}

bool invoke_lua_counter(HostState &state) noexcept
{
    if (!state.callbacks_enabled || state.ctx == nullptr)
        return false;

    if (state.attempts == std::numeric_limits<std::uint64_t>::max()) {
        std::fprintf(stderr, "[babet-fltk-prototype] counter overflow\n");
        return false;
    }

    ++state.attempts;

    babet_value argument{};
    argument.type = BABET_VALUE_INTEGER;
    argument.as.integer = static_cast<std::int64_t>(state.attempts);

    babet_value result{};
    const babet_status status =
        babet_context_call_global(state.ctx, "on_counter_click", &argument, 1,
                                  &result);
    if (status != BABET_STATUS_OK) {
        log_lua_failure(state, status);
        if (state.button != nullptr)
            state.button->copy_label("Lua error - click again");
        return false;
    }

    if (result.type != BABET_VALUE_INTEGER) {
        ++state.lua_errors;
        std::fprintf(stderr,
                     "[babet-fltk-prototype] Lua callback returned %d, expected integer\n",
                     static_cast<int>(result.type));
        if (state.button != nullptr)
            state.button->copy_label("Bad Lua result - click again");
        return false;
    }

    state.last_value = result.as.integer;
    ++state.successful_calls;

    return true;
}

void button_callback(Fl_Widget *, void *userdata) noexcept
{
    auto *state = static_cast<HostState *>(userdata);
    if (state == nullptr)
        return;

    try {
        (void)invoke_lua_counter(*state);
    } catch (const std::exception &e) {
        std::fprintf(stderr,
                     "[babet-fltk-prototype] host callback exception contained: %s\n",
                     e.what());
    } catch (...) {
        std::fprintf(stderr,
                     "[babet-fltk-prototype] unknown host callback exception contained\n");
    }
}

void close_callback(Fl_Widget *widget, void *userdata) noexcept
{
    auto *state = static_cast<HostState *>(userdata);
    if (state != nullptr)
        state->callbacks_enabled = false;

    auto *window = dynamic_cast<Fl_Window *>(widget);
    if (window != nullptr)
        window->hide();
}

bool expect_self_test(HostState &state, bool condition,
                      const char *message) noexcept
{
    if (condition)
        return true;

    std::fprintf(stderr, "[babet-fltk-prototype] SELFTEST FAIL: %s\n", message);
    state.self_test_failed = true;
    return false;
}

void schedule_self_test(HostState &state) noexcept;

void self_test_tick(void *userdata) noexcept
{
    auto *state = static_cast<HostState *>(userdata);
    if (state == nullptr || state->window == nullptr || state->button == nullptr)
        return;

    switch (state->self_test_step++) {
    case 0:
        state->button->do_callback();
        (void)expect_self_test(*state,
                               state->attempts == 1 && state->successful_calls == 1 &&
                                   state->lua_errors == 0 && state->last_value == 1 &&
                                   state->host_label_updates == 1 &&
                                   std::strcmp(state->button->label(), "Lua counter: 1") == 0,
                               "first FLTK -> Lua -> host callback did not update label");
        schedule_self_test(*state);
        break;
    case 1:
        state->button->do_callback();
        (void)expect_self_test(*state,
                               state->attempts == 2 && state->successful_calls == 1 &&
                                   state->lua_errors == 1 &&
                                   state->host_label_updates == 1,
                               "intentional Lua error did not stay inside callback boundary");
        schedule_self_test(*state);
        break;
    case 2:
        state->button->do_callback();
        (void)expect_self_test(*state,
                               state->attempts == 3 && state->successful_calls == 2 &&
                                   state->lua_errors == 1 && state->last_value == 3 &&
                                   state->host_label_updates == 2 &&
                                   std::strcmp(state->button->label(), "Lua counter: 3") == 0,
                               "event loop did not recover through Lua -> host API");
        schedule_self_test(*state);
        break;
    case 3: {
        const std::uint64_t attempts_before = state->attempts;
        state->callbacks_enabled = false;
        state->button->do_callback();
        (void)expect_self_test(*state, state->attempts == attempts_before,
                               "disabled callback still reached the Babet context");
        state->window->do_callback();
        break;
    }
    default:
        state->self_test_failed = true;
        state->window->hide();
        break;
    }
}

void schedule_self_test(HostState &state) noexcept
{
    Fl::add_timeout(0.03, self_test_tick, &state);
}

bool load_lua(HostState &state) noexcept
{
    const babet_status status = babet_context_run(
        state.ctx, kBootstrapLua.data(), kBootstrapLua.size(), "fltk-lot10-bootstrap");
    if (status == BABET_STATUS_OK)
        return true;

    std::fprintf(stderr, "[babet-fltk-prototype] bootstrap failed (%s): %s\n",
                 babet_status_name(status), babet_context_last_error(state.ctx));
    return false;
}

int run_host(bool self_test)
{
    HostState state;
    state.self_test = self_test;

    const babet_status create_status = babet_context_create(&state.ctx);
    if (create_status != BABET_STATUS_OK) {
        std::fprintf(stderr, "[babet-fltk-prototype] context create failed: %s\n",
                     babet_status_name(create_status));
        return 1;
    }

    state.window = new Fl_Window(360, 150, "Babet + FLTK Lot 10");
    state.button = new Fl_Button(70, 50, 220, 48, "Lua counter: 0");
    state.button->callback(button_callback, &state);
    state.window->callback(close_callback, &state);
    state.window->end();
    state.callbacks_enabled = true;

    const babet_status register_status = babet_context_register_host_function(
        state.ctx, "set_button_label", set_button_label_host, &state);
    if (register_status != BABET_STATUS_OK) {
        std::fprintf(stderr,
                     "[babet-fltk-prototype] host function registration failed (%s): %s\n",
                     babet_status_name(register_status),
                     babet_context_last_error(state.ctx));
        state.callbacks_enabled = false;
        delete state.window;
        state.window = nullptr;
        state.button = nullptr;
        (void)babet_context_destroy(state.ctx);
        return 1;
    }

    if (!load_lua(state)) {
        state.callbacks_enabled = false;
        delete state.window;
        state.window = nullptr;
        state.button = nullptr;
        (void)babet_context_destroy(state.ctx);
        return 1;
    }

    state.window->show();

    if (self_test)
        schedule_self_test(state);

    const int loop_status = Fl::run();

    /*
     * Destruction order is intentional:
     *   1. make callbacks inert;
     *   2. detach/destroy all FLTK objects that retain HostState pointers;
     *   3. only then destroy the Babet context.
     */
    state.callbacks_enabled = false;
    if (state.button != nullptr)
        state.button->callback(nullptr, nullptr);
    if (state.window != nullptr)
        state.window->callback(nullptr, nullptr);

    delete state.window; /* FLTK group ownership deletes the child button. */
    state.window = nullptr;
    state.button = nullptr;

    const babet_status destroy_status = babet_context_destroy(state.ctx);
    state.ctx = nullptr;

    /* The guard must stay safe even after the context has gone away. */
    button_callback(nullptr, &state);

    if (destroy_status != BABET_STATUS_OK) {
        std::fprintf(stderr, "[babet-fltk-prototype] context destroy failed: %s\n",
                     babet_status_name(destroy_status));
        return 1;
    }

    if (self_test) {
        if (state.self_test_failed || state.attempts != 3 ||
            state.successful_calls != 2 || state.lua_errors != 1 ||
            state.host_label_updates != 2 || state.last_value != 3) {
            std::fprintf(stderr,
                         "[babet-fltk-prototype] SELFTEST summary mismatch: "
                         "attempts=%llu successes=%llu lua_errors=%llu host_updates=%llu last=%lld\n",
                         static_cast<unsigned long long>(state.attempts),
                         static_cast<unsigned long long>(state.successful_calls),
                         static_cast<unsigned long long>(state.lua_errors),
                         static_cast<unsigned long long>(state.host_label_updates),
                         static_cast<long long>(state.last_value));
            return 1;
        }
        std::printf("LOT10_FLTK_HOST_API_SELFTEST_OK attempts=3 successes=2 lua_errors=1 host_updates=2 last=3\n");
    }

    return loop_status == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char **argv)
{
    bool self_test = false;
    if (argc == 2 && std::strcmp(argv[1], "--self-test") == 0) {
        self_test = true;
    } else if (argc != 1) {
        std::fprintf(stderr, "usage: %s [--self-test]\n", argv[0]);
        return 2;
    }

    return run_host(self_test);
}
