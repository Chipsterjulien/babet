#include <babet/babet.h>

#include <stdio.h>
#include <string.h>

int main(void)
{
    babet_context *ctx = NULL;
    babet_status status = babet_context_create(&ctx);
    if (status != BABET_STATUS_OK) {
        fprintf(stderr, "create: %s\n", babet_status_name(status));
        return 1;
    }

    printf("embedded Babet %s\n", babet_version());
    static const char code[] =
        "assert(babet.base64.encode('hello') == 'aGVsbG8=')";
    status = babet_context_run(ctx, code, strlen(code), "hello-example");
    if (status != BABET_STATUS_OK) {
        fprintf(stderr, "run: %s: %s\n", babet_status_name(status),
                babet_context_last_error(ctx));
        (void)babet_context_destroy(ctx);
        return 1;
    }

    status = babet_context_destroy(ctx);
    if (status != BABET_STATUS_OK) {
        fprintf(stderr, "destroy: %s\n", babet_status_name(status));
        return 1;
    }
    return 0;
}
