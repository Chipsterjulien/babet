#include <babet/babet.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    babet_context *ctx = NULL;
    babet_status status = babet_context_create(&ctx);
    if (status != BABET_STATUS_OK)
        return 1;

    static const char code[] =
        "function add_from_host(a, b) return a + b end\n"
        "function no_result() end\n";
    status = babet_context_run(ctx, code, strlen(code), "call-example");
    if (status != BABET_STATUS_OK) {
        fprintf(stderr, "%s\n", babet_context_last_error(ctx));
        (void)babet_context_destroy(ctx);
        return 1;
    }

    babet_value args[2] = {0};
    args[0].type = BABET_VALUE_INTEGER;
    args[0].as.integer = INT64_C(19);
    args[1].type = BABET_VALUE_INTEGER;
    args[1].as.integer = INT64_C(23);

    babet_value result = {0};
    status = babet_context_call_global(ctx, "add_from_host", args, 2, &result);
    if (status != BABET_STATUS_OK || result.type != BABET_VALUE_INTEGER ||
        result.as.integer != INT64_C(42)) {
        fprintf(stderr, "call failed: %s: %s\n", babet_status_name(status),
                babet_context_last_error(ctx));
        (void)babet_context_destroy(ctx);
        return 1;
    }

    status = babet_context_call_global(ctx, "no_result", NULL, 0, &result);
    if (status != BABET_STATUS_OK || result.type != BABET_VALUE_NIL) {
        fprintf(stderr, "no-result semantics mismatch\n");
        (void)babet_context_destroy(ctx);
        return 1;
    }

    return babet_context_destroy(ctx) == BABET_STATUS_OK ? 0 : 1;
}
