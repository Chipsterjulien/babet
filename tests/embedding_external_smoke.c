#include <babet/babet.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int expect_status(const char *label, babet_status actual,
                         babet_status expected)
{
    if (actual == expected)
        return 1;
    fprintf(stderr, "%s: expected %s, got %s\n", label,
            babet_status_name(expected), babet_status_name(actual));
    return 0;
}

int main(void)
{
    babet_context *context = NULL;
    if (!expect_status("create", babet_context_create(&context),
                       BABET_STATUS_OK) || context == NULL)
        return 1;

    static const char chunk[] =
        "assert(babet.base64.encode('sdk') == 'c2Rr')\n"
        "function sdk_add(a, b) return a + b end\n";
    if (!expect_status("run", babet_context_run(context, chunk,
                                                 sizeof(chunk) - 1,
                                                 "external-sdk-smoke"),
                       BABET_STATUS_OK))
    {
        fprintf(stderr, "%s\n", babet_context_last_error(context));
        (void)babet_context_destroy(context);
        return 1;
    }

    babet_value args[2] = {0};
    args[0].type = BABET_VALUE_INTEGER;
    args[0].as.integer = INT64_C(19);
    args[1].type = BABET_VALUE_INTEGER;
    args[1].as.integer = INT64_C(23);
    babet_value result = {0};
    if (!expect_status("call", babet_context_call_global(context, "sdk_add",
                                                          args, 2, &result),
                       BABET_STATUS_OK) ||
        result.type != BABET_VALUE_INTEGER || result.as.integer != INT64_C(42))
    {
        fprintf(stderr, "external SDK scalar call mismatch: %s\n",
                babet_context_last_error(context));
        (void)babet_context_destroy(context);
        return 1;
    }

    if (!expect_status("destroy", babet_context_destroy(context),
                       BABET_STATUS_OK))
        return 1;

    puts("embedding external SDK smoke: PASS");
    return 0;
}
