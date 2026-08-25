#include <babet/babet.h>

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <module-root>\n", argv[0]);
        return 2;
    }

    babet_context *ctx = NULL;
    babet_status status = babet_context_create(&ctx);
    if (status != BABET_STATUS_OK) {
        fprintf(stderr, "create: %s\n", babet_status_name(status));
        return 1;
    }

    status = babet_context_set_search_root(ctx, argv[1]);
    if (status != BABET_STATUS_OK) {
        fprintf(stderr, "search root: %s: %s\n", babet_status_name(status),
                babet_context_last_error(ctx));
        (void)babet_context_destroy(ctx);
        return 1;
    }

    static const char code[] =
        "local greeting = require('greeting')\n"
        "assert(greeting.message == 'hello from host module')\n";
    status = babet_context_run(ctx, code, strlen(code), "search-root-example");
    if (status != BABET_STATUS_OK) {
        fprintf(stderr, "run: %s: %s\n", babet_status_name(status),
                babet_context_last_error(ctx));
        (void)babet_context_destroy(ctx);
        return 1;
    }

    return babet_context_destroy(ctx) == BABET_STATUS_OK ? 0 : 1;
}
