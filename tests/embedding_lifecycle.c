#include <babet/babet.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static babet_status raise_usr1(babet_host_call *call, void *userdata)
{
    (void)call;
    (void)userdata;
    return raise(SIGUSR1) == 0 ? BABET_STATUS_OK : BABET_STATUS_INTERNAL_ERROR;
}

static int run_signal_case(const char *name, const char *chunk)
{
    babet_context *context = NULL;
    if (babet_context_create(&context) != BABET_STATUS_OK)
        return 0;
    babet_status status = babet_context_register_host_function(
        context, "test_raise_usr1", raise_usr1, NULL);
    if (status == BABET_STATUS_OK)
        status = babet_context_run(context, chunk, strlen(chunk), name);
    if (status != BABET_STATUS_OK)
        fprintf(stderr, "[FAIL] %s: %s\n", name, babet_context_last_error(context));
    /* Restore the test signal even when an assertion failed. */
    (void)signal(SIGUSR1, SIG_DFL);
    babet_status destroyed = babet_context_destroy(context);
    if (status != BABET_STATUS_OK || destroyed != BABET_STATUS_OK)
        return 0;
    printf("[PASS] %s\n", name);
    return 1;
}

typedef struct destruction_probe
{
    unsigned calls;
    int thread_error;
    babet_status direct_status;
    babet_status concurrent_status;
    int direct_null;
    int concurrent_null;
} destruction_probe;

static void *try_create_concurrently(void *userdata)
{
    destruction_probe *probe = (destruction_probe *)userdata;
    babet_context *other = NULL;
    probe->concurrent_status = babet_context_create(&other);
    probe->concurrent_null = other == NULL;
    if (other) (void)babet_context_destroy(other);
    return NULL;
}

static babet_status probe_during_finalizer(babet_host_call *call, void *userdata)
{
    (void)call;
    destruction_probe *probe = (destruction_probe *)userdata;
    ++probe->calls;
    babet_context *other = NULL;
    probe->direct_status = babet_context_create(&other);
    probe->direct_null = other == NULL;
    if (other) (void)babet_context_destroy(other);
    pthread_t thread;
    probe->thread_error = pthread_create(&thread, NULL, try_create_concurrently, probe);
    if (probe->thread_error == 0)
        probe->thread_error = pthread_join(thread, NULL);
    return BABET_STATUS_OK;
}

int babet_test_lifecycle(void)
{
    /* Turn a regression that holds the context mutex across a finalizer
     * into a bounded failure, including in the official sanitizer host. */
    alarm(30);
    static const char main_chunk[] =
        "assert(debug.gethook()==nil); "
        "local hits=0; assert(babet.signal.handle('USR1',function() hits=hits+1 end)); "
        "babet.host.test_raise_usr1(); for i=1,100000 do local n=i+1 end; assert(hits==1, hits)";
    if (!run_signal_case("signal dispatch in first context", main_chunk) ||
        !run_signal_case("signal dispatch in recreated context", main_chunk))
        return 0;
    if (!run_signal_case("signal registration from coroutine reaches main loop",
        "local hits=0; local c=coroutine.create(function() "
        "assert(babet.signal.handle('USR1',function() hits=hits+1 end)) end); "
        "assert(coroutine.resume(c)); babet.host.test_raise_usr1(); "
        "for i=1,100000 do local n=i+1 end; assert(hits==1,hits)"))
        return 0;
    if (!run_signal_case("coroutine created after handle inherits dispatch",
        "local hits=0; local active; "
        "assert(babet.signal.handle('USR1',function() hits=hits+1; active=coroutine.running() end)); "
        "local c=coroutine.create(function() babet.host.test_raise_usr1(); "
        "for i=1,100000 do local n=i+1 end; assert(hits==1,hits) end); "
        "assert(coroutine.resume(c)); assert(active==c)"))
        return 0;
    if (!run_signal_case("early coroutine is unchanged until its own handle call",
        "local hits=0; local active; local c=coroutine.create(function() "
        "assert(debug.gethook()==nil); "
        "assert(babet.signal.handle('USR1',function() hits=hits+1; active=coroutine.running() end)); "
        "babet.host.test_raise_usr1(); for i=1,100000 do local n=i+1 end; assert(hits==1,hits) end); "
        "assert(babet.signal.handle('USR1',function() hits=hits+1; active=coroutine.running() end)); "
        "assert(debug.gethook(c)==nil); "
        "assert(coroutine.resume(c)); assert(active==c)"))
        return 0;
    if (!run_signal_case("nested coroutine.wrap inherits dispatch",
        "local hits=0; assert(babet.signal.handle('USR1',function() hits=hits+1 end)); "
        "coroutine.wrap(function() coroutine.wrap(function() babet.host.test_raise_usr1(); "
        "for i=1,100000 do local n=i+1 end; assert(hits==1,hits) end)() end)()"))
        return 0;
    if (!run_signal_case("handle restores dispatch after debug.sethook",
        "local hits=0; local fn=function() hits=hits+1 end; assert(babet.signal.handle('USR1',fn)); "
        "debug.sethook(function() end,'',100); assert(babet.signal.handle('USR1',fn)); "
        "babet.host.test_raise_usr1(); for i=1,100000 do local n=i+1 end; assert(hits==1,hits)"))
        return 0;
    if (!run_signal_case("coroutine handle restores both replaced hooks",
        "local hits=0; local fn=function() hits=hits+1 end; "
        "debug.sethook(function() end,'',100); local c=coroutine.create(function() "
        "assert(babet.signal.handle('USR1',fn)); babet.host.test_raise_usr1(); "
        "for i=1,100000 do local n=i+1 end; assert(hits==1,hits) end); "
        "assert(coroutine.resume(c)); babet.host.test_raise_usr1(); "
        "for i=1,100000 do local n=i+1 end; assert(hits==2,hits)"))
        return 0;
    if (!run_signal_case("debug hook override remains explicit",
        "local hits=0; local user_hits=0; local fn=function() hits=hits+1 end; "
        "assert(babet.signal.handle('USR1',fn)); debug.sethook(function() user_hits=user_hits+1 end,'',100); "
        "babet.host.test_raise_usr1(); for i=1,100000 do local n=i+1 end; assert(hits==0 and user_hits>0); "
        "assert(babet.signal.handle('USR1',fn)); for i=1,100000 do local n=i+1 end; assert(hits==1,hits)"))
        return 0;
    if (!run_signal_case("worker cannot configure main-thread signals",
        "local job=assert(babet.workers.spawn([[local ok,err=pcall(babet.signal.handle,'USR1',function() end); "
        "return not ok and err:find('main thread',1,true)~=nil]])); "
        "local ok,v=job:join(10); assert(ok and v==true,tostring(v))"))
        return 0;

    /* The preceding worker case freezes process state. Destroying its
     * context must not reset that mark in the next Lua state. */
    static const char locale_chunk[] =
        "local before=os.setlocale(); assert(type(before)=='string'); "
        "local ok,err=pcall(os.setlocale,'C'); "
        "assert(not ok and err:find('workers.spawn',1,true),tostring(err)); "
        "assert(os.setlocale()==before)";
    if (!run_signal_case("locale frozen in recreated context", locale_chunk) ||
        !run_signal_case("locale freeze survives another context recreation", locale_chunk))
        return 0;

    destruction_probe probe = {0};
    babet_context *context = NULL;
    if (babet_context_create(&context) != BABET_STATUS_OK)
        return 0;
    if (babet_context_register_host_function(context, "test_during_close",
                                             probe_during_finalizer, &probe) != BABET_STATUS_OK)
        return 0;
    static const char finalizer[] =
        "finalizer_anchor=setmetatable({}, {__gc=function() babet.host.test_during_close() end})";
    if (babet_context_run(context, finalizer, sizeof(finalizer)-1, "finalizer-probe") != BABET_STATUS_OK)
        return 0;
    if (babet_context_destroy(context) != BABET_STATUS_OK)
        return 0;
    if (probe.calls != 1 || probe.thread_error != 0 ||
        probe.direct_status != BABET_STATUS_BUSY || !probe.direct_null ||
        probe.concurrent_status != BABET_STATUS_BUSY || !probe.concurrent_null)
    {
        fprintf(stderr, "[FAIL] context slot during finalization: calls=%u direct=%u concurrent=%u thread=%d\n",
                probe.calls, (unsigned)probe.direct_status,
                (unsigned)probe.concurrent_status, probe.thread_error);
        return 0;
    }
    puts("[PASS] finalizer host reentry returns BUSY without deadlock");
    puts("[PASS] concurrent create remains BUSY during destruction");
    if (babet_context_create(&context) != BABET_STATUS_OK || !context ||
        babet_context_destroy(context) != BABET_STATUS_OK)
        return 0;
    puts("[PASS] create succeeds after complete destruction");
    puts("embedding lifecycle: 15 PASS / 0 FAIL");
    alarm(0);
    return 1;
}
