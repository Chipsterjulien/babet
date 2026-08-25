#include <babet/babet.h>

#include <stdio.h>
#include <string.h>

typedef struct greeting_state
{
    unsigned calls;
} greeting_state;

static babet_status host_greet(babet_host_call *call, void *userdata)
{
    greeting_state *state = (greeting_state *)userdata;
    const size_t count = babet_host_call_argument_count(call);
    const babet_value *arguments = babet_host_call_arguments(call);

    if (state == NULL || count != 1 || arguments == NULL ||
        arguments[0].type != BABET_VALUE_STRING)
    {
        (void)babet_host_call_set_error(
            call, "greet expects exactly one string argument");
        return BABET_STATUS_INVALID_ARGUMENT;
    }

    char buffer[128];
    const int written = snprintf(buffer, sizeof(buffer), "Hello, %.*s!",
                                 (int)arguments[0].as.string.length,
                                 arguments[0].as.string.data);
    if (written < 0 || (size_t)written >= sizeof(buffer))
    {
        (void)babet_host_call_set_error(call, "greeting is too long");
        return BABET_STATUS_INVALID_ARGUMENT;
    }

    ++state->calls;
    babet_value result = {0};
    result.type = BABET_VALUE_STRING;
    result.as.string.data = buffer;
    result.as.string.length = (size_t)written;

    /* Babet copies the temporary buffer synchronously here. */
    return babet_host_call_set_result(call, &result);
}

int main(void)
{
    babet_context *context = NULL;
    greeting_state state = {0};

    babet_status status = babet_context_create(&context);
    if (status != BABET_STATUS_OK)
        return 1;

    status = babet_context_register_host_function(
        context, "greet", host_greet, &state);
    if (status != BABET_STATUS_OK)
    {
        fprintf(stderr, "register: %s\n", babet_context_last_error(context));
        (void)babet_context_destroy(context);
        return 1;
    }

    static const char script[] =
        "local message = babet.host.greet('Lua')\n"
        "assert(message == 'Hello, Lua!')\n";
    status = babet_context_run(context, script, sizeof(script) - 1,
                               "host-function-example");
    if (status != BABET_STATUS_OK)
    {
        fprintf(stderr, "run: %s\n", babet_context_last_error(context));
        (void)babet_context_destroy(context);
        return 1;
    }

    if (state.calls != 1)
    {
        fprintf(stderr, "host callback was called %u times\n", state.calls);
        (void)babet_context_destroy(context);
        return 1;
    }

    return babet_context_destroy(context) == BABET_STATUS_OK ? 0 : 1;
}
