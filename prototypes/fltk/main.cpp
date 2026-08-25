#include <FL/Fl.H>
#include <FL/Fl_Button.H>
#include <FL/Fl_Window.H>

#include <babet/babet.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <limits>
#include <string_view>

namespace {

constexpr std::string_view kBootstrapLua = R"lua(
function on_counter_click(attempt)
    if attempt == 2 then
        error("intentional Lot 9 callback failure")
    end
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
    std::int64_t last_value = 0;
};

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

    if (state.button != nullptr) {
        char label[96];
        const int written = std::snprintf(label, sizeof(label), "Lua counter: %lld",
                                          static_cast<long long>(state.last_value));
        if (written > 0 && static_cast<std::size_t>(written) < sizeof(label))
            state.button->copy_label(label);
    }

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
                                   state->lua_errors == 0 && state->last_value == 1,
                               "first FLTK -> Lua callback did not return 1");
        schedule_self_test(*state);
        break;
    case 1:
        state->button->do_callback();
        (void)expect_self_test(*state,
                               state->attempts == 2 && state->successful_calls == 1 &&
                                   state->lua_errors == 1,
                               "intentional Lua error did not stay inside callback boundary");
        schedule_self_test(*state);
        break;
    case 2:
        state->button->do_callback();
        (void)expect_self_test(*state,
                               state->attempts == 3 && state->successful_calls == 2 &&
                                   state->lua_errors == 1 && state->last_value == 3,
                               "event loop did not recover after Lua callback error");
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
        state.ctx, kBootstrapLua.data(), kBootstrapLua.size(), "fltk-lot9-bootstrap");
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

    if (!load_lua(state)) {
        (void)babet_context_destroy(state.ctx);
        return 1;
    }

    state.window = new Fl_Window(360, 150, "Babet + FLTK Lot 9");
    state.button = new Fl_Button(70, 50, 220, 48, "Lua counter: 0");
    state.button->callback(button_callback, &state);
    state.window->callback(close_callback, &state);
    state.window->end();
    state.callbacks_enabled = true;
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
            state.last_value != 3) {
            std::fprintf(stderr,
                         "[babet-fltk-prototype] SELFTEST summary mismatch: "
                         "attempts=%llu successes=%llu lua_errors=%llu last=%lld\n",
                         static_cast<unsigned long long>(state.attempts),
                         static_cast<unsigned long long>(state.successful_calls),
                         static_cast<unsigned long long>(state.lua_errors),
                         static_cast<long long>(state.last_value));
            return 1;
        }
        std::printf("LOT9_FLTK_SELFTEST_OK attempts=3 successes=2 lua_errors=1 last=3\n");
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
