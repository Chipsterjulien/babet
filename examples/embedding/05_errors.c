#include <babet/babet.h>

#include <stdio.h>
#include <string.h>

int main(void)
{
    babet_context *ctx = NULL;
    babet_status status = babet_context_create(&ctx);
    if (status != BABET_STATUS_OK)
        return 1;

    static const char bad_code[] = "error('expected example failure')";
    status = babet_context_run(ctx, bad_code, strlen(bad_code), "errors-example");
    if (status != BABET_STATUS_LUA_ERROR) {
        fprintf(stderr, "expected lua_error, got %s\n", babet_status_name(status));
        (void)babet_context_destroy(ctx);
        return 1;
    }

    const char *diagnostic = babet_context_last_error(ctx);
    if (!diagnostic || strstr(diagnostic, "expected example failure") == NULL) {
        fprintf(stderr, "missing Lua diagnostic\n");
        (void)babet_context_destroy(ctx);
        return 1;
    }
    fprintf(stderr, "expected failure: %s\n", diagnostic);

    static const char good_code[] = "recovered = 42";
    status = babet_context_run(ctx, good_code, strlen(good_code), "recovery-example");
    if (status != BABET_STATUS_OK) {
        fprintf(stderr, "recovery failed: %s\n", babet_context_last_error(ctx));
        (void)babet_context_destroy(ctx);
        return 1;
    }

    babet_value value = {0};
    status = babet_context_get_global(ctx, "recovered", &value);
    if (status != BABET_STATUS_OK || value.type != BABET_VALUE_INTEGER ||
        value.as.integer != 42) {
        fprintf(stderr, "recovery value mismatch\n");
        (void)babet_context_destroy(ctx);
        return 1;
    }

    return babet_context_destroy(ctx) == BABET_STATUS_OK ? 0 : 1;
}
