#include <babet/babet.h>

#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef struct thread_probe {
    babet_context *ctx;
    babet_status status;
} thread_probe;

static void *wrong_thread_run(void *opaque)
{
    thread_probe *probe = (thread_probe *)opaque;
    static const char code[] = "return 1";
    probe->status = babet_context_run(probe->ctx, code, strlen(code),
                                      "wrong-thread-example");
    return NULL;
}

int main(void)
{
    babet_context *ctx = NULL;
    babet_status status = babet_context_create(&ctx);
    if (status != BABET_STATUS_OK)
        return 1;

    babet_context *second = NULL;
    status = babet_context_create(&second);
    if (status != BABET_STATUS_BUSY || second != NULL) {
        fprintf(stderr, "second context was not rejected with busy\n");
        (void)babet_context_destroy(ctx);
        return 1;
    }

    thread_probe probe = {ctx, BABET_STATUS_OK};
    pthread_t thread;
    if (pthread_create(&thread, NULL, wrong_thread_run, &probe) != 0) {
        (void)babet_context_destroy(ctx);
        return 1;
    }
    if (pthread_join(thread, NULL) != 0) {
        (void)babet_context_destroy(ctx);
        return 1;
    }
    if (probe.status != BABET_STATUS_WRONG_THREAD) {
        fprintf(stderr, "wrong-thread call returned %s\n",
                babet_status_name(probe.status));
        (void)babet_context_destroy(ctx);
        return 1;
    }

    if (babet_context_destroy(ctx) != BABET_STATUS_OK)
        return 1;

    status = babet_context_create(&second);
    if (status != BABET_STATUS_OK || second == NULL) {
        fprintf(stderr, "sequential recreation failed: %s\n",
                babet_status_name(status));
        return 1;
    }

    return babet_context_destroy(second) == BABET_STATUS_OK ? 0 : 1;
}
