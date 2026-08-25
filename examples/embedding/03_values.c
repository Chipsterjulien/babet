#include <babet/babet.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int fail(babet_context *ctx, const char *label, babet_status status)
{
    fprintf(stderr, "%s: %s: %s\n", label, babet_status_name(status),
            ctx ? babet_context_last_error(ctx) : "");
    if (ctx)
        (void)babet_context_destroy(ctx);
    return 1;
}

int main(void)
{
    babet_context *ctx = NULL;
    babet_status status = babet_context_create(&ctx);
    if (status != BABET_STATUS_OK)
        return fail(NULL, "create", status);

    babet_value value = {0};
    value.type = BABET_VALUE_INTEGER;
    value.as.integer = INT64_C(42);
    status = babet_context_set_global(ctx, "host_answer", &value);
    if (status != BABET_STATUS_OK)
        return fail(ctx, "set integer", status);

    value.type = BABET_VALUE_BOOLEAN;
    value.as.boolean = 1;
    status = babet_context_set_global(ctx, "host_enabled", &value);
    if (status != BABET_STATUS_OK)
        return fail(ctx, "set boolean", status);

    value.type = BABET_VALUE_NUMBER;
    value.as.number = 3.5;
    status = babet_context_set_global(ctx, "host_number", &value);
    if (status != BABET_STATUS_OK)
        return fail(ctx, "set number", status);

    static const char binary[] = {'A', '\0', 'B', '\0', 'C'};
    value.type = BABET_VALUE_STRING;
    value.as.string.data = binary;
    value.as.string.length = sizeof(binary);
    status = babet_context_set_global(ctx, "host_binary", &value);
    if (status != BABET_STATUS_OK)
        return fail(ctx, "set binary", status);

    value.type = BABET_VALUE_NIL;
    status = babet_context_set_global(ctx, "host_nil", &value);
    if (status != BABET_STATUS_OK)
        return fail(ctx, "set nil", status);

    static const char code[] =
        "assert(host_answer == 42)\n"
        "assert(host_enabled == true)\n"
        "assert(host_number == 3.5)\n"
        "assert(host_nil == nil)\n"
        "assert(#host_binary == 5 and host_binary:byte(2) == 0)\n"
        "lua_binary = host_binary .. string.char(0x21)\n";
    status = babet_context_run(ctx, code, strlen(code), "values-example");
    if (status != BABET_STATUS_OK)
        return fail(ctx, "run", status);

    babet_value result = {0};
    status = babet_context_get_global(ctx, "lua_binary", &result);
    if (status != BABET_STATUS_OK)
        return fail(ctx, "get binary", status);

    static const char expected[] = {'A', '\0', 'B', '\0', 'C', '!'};
    if (result.type != BABET_VALUE_STRING ||
        result.as.string.length != sizeof(expected) ||
        memcmp(result.as.string.data, expected, sizeof(expected)) != 0) {
        fprintf(stderr, "binary round-trip mismatch\n");
        (void)babet_context_destroy(ctx);
        return 1;
    }

    return babet_context_destroy(ctx) == BABET_STATUS_OK ? 0 : 1;
}
