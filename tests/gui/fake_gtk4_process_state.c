#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// A real native thread starts at dlopen time, before gtk_init_check. It stays
// alive until unload/process exit; this fixture never races libc mutations.
static pthread_t thread;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int ready;
static int stopping;
static void *background(void *unused)
{
    (void)unused;
    pthread_mutex_lock(&mutex);
    ready = 1;
    pthread_cond_broadcast(&condition);
    while (!stopping) pthread_cond_wait(&condition, &mutex);
    pthread_mutex_unlock(&mutex);
    return NULL;
}

__attribute__((constructor)) static void start_thread(void)
{
    // The standalone probe exports this hook. Calling it also verifies that
    // the process-state mutex is not held across dlopen constructors.
    void *symbol = dlsym(RTLD_DEFAULT, "babet_test_mutation_allowed");
    if (symbol)
    {
        int (*allowed)(void);
        _Static_assert(sizeof(allowed) == sizeof(symbol), "POSIX function pointer");
        memcpy(&allowed, &symbol, sizeof(allowed));
        if (allowed()) _Exit(86);
    }
    if (pthread_create(&thread, NULL, background, NULL) != 0) _Exit(87);
    pthread_mutex_lock(&mutex);
    while (!ready) pthread_cond_wait(&condition, &mutex);
    pthread_mutex_unlock(&mutex);
}

__attribute__((destructor)) static void stop_thread(void)
{
    pthread_mutex_lock(&mutex);
    stopping = 1;
    pthread_cond_broadcast(&condition);
    pthread_mutex_unlock(&mutex);
    pthread_join(thread, NULL);
}

#include "fake_gtk4_good.c"
